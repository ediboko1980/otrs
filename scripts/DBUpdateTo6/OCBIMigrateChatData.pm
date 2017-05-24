# --
# Copyright (C) 2001-2017 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package scripts::DBUpdateTo6::OCBIMigrateChatData;    ## no critic

use strict;
use warnings;

use parent qw(scripts::DBUpdateTo6::Base);

our @ObjectDependencies = (
    'Kernel::System::DB',
    'Kernel::System::Log',
    'Kernel::System::JSON',
    'Kernel::System::YAML',
);

=head1 NAME

scripts::DBUpdateTo6::OCBIMigrateChatData -  Migrate Chat data.

=cut

sub Run {
    my ( $Self, %Param ) = @_;

    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    my %Tables = map { lc($_) => 1 } $DBObject->ListTables();
    return 1 if !$Tables{article_data_otrs_chat};

    return if !$DBObject->Prepare(
        SQL => 'SELECT id, name FROM communication_channel',
    );

    # Look for the chat channel id
    my $ChatChannelID;
    while ( my @Row = $DBObject->FetchrowArray() ) {
        if ( $Row[1] =~ /chat/i ) {
            $ChatChannelID = $Row[0];
        }
    }

    return 1 if !$ChatChannelID;

    my $ArticleChatCount = 0;
    my $ChatCount        = 0;

    # Get amount of article entries
    $DBObject->Prepare(
        SQL  => "SELECT COUNT(*) FROM article WHERE communication_channel_id = ? ",
        Bind => [ \$ChatChannelID ]
    );
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $ArticleChatCount = $Row[0] || 0;
    }

    # Get amount of article entries
    $DBObject->Prepare(
        SQL => "SELECT COUNT(*) FROM article_data_otrs_chat",
    );
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $ChatCount = $Row[0] || 0;
    }

    # Chat info should be present in chat channel table
    # not in article table
    if ( $ChatCount && !$ArticleChatCount ) {
        print STDERR "\n Chat data migration already executed \n";
    }

    my $ArticleChatMin = 0;

    # Get amount of article entries
    $DBObject->Prepare(
        SQL  => "SELECT MIN(id) FROM article WHERE communication_channel_id = ? ",
        Bind => [ \$ChatChannelID ]
    );
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $ArticleChatMin = $Row[0] || 0;
    }

    my $ArticleChatMax = 0;

    # Get amount of article entries
    $DBObject->Prepare(
        SQL  => "SELECT MAX(id) FROM article WHERE communication_channel_id = ? ",
        Bind => [ \$ChatChannelID ]
    );
    while ( my @Row = $DBObject->FetchrowArray() ) {
        $ArticleChatMax = $Row[0] || 0;
    }

    # TODO:OCBI: This number might be changed or even configurable
    my $RowsPerLoop = 1000;

    my $StartInEntry = $ArticleChatMin - 1 || 0;

    my $JSONObject = $Kernel::OM->Get('Kernel::System::JSON');

    ENTRIES:
    while ( $StartInEntry < $ArticleChatMax ) {

        # Get the complete set of Article entries.
        my $EndInEntry = $StartInEntry + 1 + $RowsPerLoop;

        return if !$DBObject->Prepare(
            SQL => '
                SELECT adm.id, adm.article_id, adm.a_body,
                    adm.create_by, adm.create_time, adm.change_by, adm.change_time
                FROM article art, article_data_mime adm
                WHERE
                    art.id = adm.article_id
                    AND art.communication_channel_id = ?
                    AND adm.id > ' . $StartInEntry . ' AND adm.id < ' . $EndInEntry . '
                ORDER BY id ASC',
            Bind => [ \$ChatChannelID ],
        );

        my @Data;
        while ( my @Row = $DBObject->FetchrowArray() ) {
            my $ArticleJSONData = $JSONObject->Decode(
                Data => $Row[2],
            );

            for my $ArticleJSON ( @{$ArticleJSONData} ) {

                my %CurrentRow = (
                    ID                  => $ArticleJSON->{ID},
                    ArticleID           => $Row[1],
                    ChatParticipantID   => $ArticleJSON->{ChatterID},
                    ChatParticipantName => $ArticleJSON->{ChatterName},
                    ChatParticipantType => $ArticleJSON->{ChatterType},
                    MessageText         => $ArticleJSON->{MessageText},
                    SystemGenerated     => $ArticleJSON->{SystemGenerated},
                    CreateTime          => $Row[4],
                );
                push @Data, \%CurrentRow;
            }
        }

        # Finish silently in case no data
        last ENTRIES if !@Data;

        my $MigrationResult = $Self->_MigrateData(
            Data              => \@Data,
            LastArticleDataID => $Data[-1]->{ID},
        );

        if ( !$MigrationResult ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "An error occurs during chat data migration!",
            );
            return;
        }

        my $DataSize = scalar @Data;

        $StartInEntry += $DataSize;
    }

    # Delete old chat articles.
    my $DeleteResult = $Self->_DeleteOldChatArticles(
        ChatChannelID => $ChatChannelID,
    );

    if ( !$DeleteResult ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "An error occurs during article chat data cleanup!",
        );
        return;
    }

    return 1;
}

=head2 _MigrateData()

Adds multiple article entries to the article table. Returns 1 on success

    my $Result = $DBUpdateTo6Object->_MigrateData(
        Data => \@OldArticleData, # Old structure content
    );

=cut

sub _MigrateData {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    if ( !$Param{Data} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need Data!",
        );
        return;
    }

    # Check needed stuff.
    if ( ref $Param{Data} ne 'ARRAY' ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Data must be an array reference!",
        );
        return;
    }

    # Check needed stuff.
    if ( !@{ $Param{Data} } ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Data array must not be empty!",
        );
        return;
    }

    # Check needed stuff.
    if ( !defined $Param{LastArticleDataID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need LastArticleDataID!",
        );
        return;
    }

    my $DBObject = $Kernel::OM->Get('Kernel::System::DB');

    # Get the database type.
    my $DBType = $DBObject->GetDatabaseFunction('Type');

    # Decide data migration type.
    my $AllowMultiple          = 1;
    my @SupportMultipleInserts = qw(mysql oracle postgresql);

    if ( !grep( /$DBType/, @SupportMultipleInserts ) ) {
        $AllowMultiple = 0;
    }

    # Define database specific SQL for the multi-line inserts.
    my %DatabaseSQL;

    if ( $DBType eq 'oracle' && $AllowMultiple ) {

        %DatabaseSQL = (
            Start     => 'INSERT ALL ',
            FirstLine => '
                INTO article_data_otrs_chat (
                    article_id,chat_participant_id,chat_participant_name,
                    chat_participant_type,message_text,system_generated,create_time
                )
                VALUES ( ?, ?, ?, ?, ?, ?, ? ) ',
            NextLine => '
                INTO article_data_otrs_chat (
                    article_id,chat_participant_id,chat_participant_name,
                    chat_participant_type,message_text,system_generated,create_time
                )
                VALUES ( ?, ?, ?, ?, ?, ?, ? ) ',
            End => 'SELECT * FROM DUAL',
        );
    }
    else {
        %DatabaseSQL = (
            Start => '
                INSERT INTO article_data_otrs_chat (
                    article_id,chat_participant_id,chat_participant_name,
                    chat_participant_type,message_text,system_generated,create_time
                )',
            FirstLine => 'VALUES ( ?, ?, ?, ?, ?, ?, ? )',
            NextLine  => ', ( ?, ?, ?, ?, ?, ?, ? ) ',
            End       => '',
        );

    }

    my $SQL = '';
    my @Bind;

    ARTICLEENTRY:
    for my $ArticleEntry ( @{ $Param{Data} } ) {

        # Now the article entry is validated and can be added to sql.
        if ( !$SQL ) {
            $SQL = $DatabaseSQL{Start} . $DatabaseSQL{FirstLine};
        }
        else {
            $SQL .= $DatabaseSQL{NextLine};
        }

        push @Bind, (
            \$ArticleEntry->{ArticleID},
            \$ArticleEntry->{ChatParticipantID},
            \$ArticleEntry->{ChatParticipantName},
            \$ArticleEntry->{ChatParticipantType},
            \$ArticleEntry->{MessageText},
            \$ArticleEntry->{SystemGenerated},
            \$ArticleEntry->{CreateTime},
        );

        # Check the length of the SQL string
        # (some databases only accept SQL strings up to 4k,
        # so we want to stay safe here with just 3500 bytes).
        if ( length $SQL > 3500 || !$AllowMultiple || $ArticleEntry->{ID} == $Param{LastArticleDataID} ) {

            # Add the end line to sql string.
            $SQL .= $DatabaseSQL{End};

            # Insert multiple history entries.
            return if !$DBObject->Do(
                SQL  => $SQL,
                Bind => \@Bind,
            );

            # Reset the SQL string and the Bind array.
            $SQL  = '';
            @Bind = ();
        }
    }

    return 1;
}

=head2 _DeleteOldChatArticles()

Delete chat data from the article table. Returns 1 on success

    my $Result = $DBUpdateTo6Object->_DeleteOldChatArticles(
        ChatChannelID => $ChatChannelID, # ID of chat channel
    );

=cut

sub _DeleteOldChatArticles {
    my ( $Self, %Param ) = @_;

    # Check needed stuff.
    if ( !$Param{ChatChannelID} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Need ChatChannelID!",
        );
        return;
    }

    # Delete chat article data.
    return if !$Kernel::OM->Get('Kernel::System::DB')->Do(
        SQL => '
            DELETE FROM article_data_mime
            WHERE
                article_id IN (
                    SELECT id
                    FROM article
                    WHERE communication_channel_id = ?
                )
        ',
        Bind => [ \$Param{ChatChannelID} ],
    );

    return 1;
}

1;

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut
