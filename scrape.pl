#!/usr/bin/perl
use strict;
use warnings;
use Scrappy qw/:syntax/;
use Data::Dumper;
use Text::CSV_XS;
use autodie;

# Load any existing data into memory so we can avoid dups
my $data_file = "ca_corps.csv";
my $data = load_data($data_file);

# Open up the file for append
my $csv = Text::CSV_XS->new;
$csv->eol("\n");

my $search_num = 63616;
my $work_it = 1;
$SIG{INT} = sub { $work_it = 0 };
while ($work_it) {
    my $search_term = sprintf "%05i", $search_num++;
    open my $wfh, ">>:encoding(utf8)", $data_file;
    search_and_scrape($wfh, $search_term, 5);
    close $wfh;
}
exit;

sub search_and_scrape {
    my $wfh = shift;
    my $search = shift;
    my $tries = shift;
    warn "Searching for '$search' ...\n";
    eval {
        post "https://www.ic.gc.ca/app/scr/cc/CorporationsCanada/fdrlCrpSrch.html?locale=en_CA", {
            'V_SEARCH.docsStart' => 1,
            'V_SEARCH.baseURL' => "fdrlCrpSrch.html",
            'V_SEARCH.command' => 'search',
            corpNumber => $search,
        };
    };
    if ($@) {
        die "Failed to POST: $@" unless $tries;
        sleep 20;
        warn "Trying again (tries left: $tries)";
        return search_and_scrape($wfh, $search, --$tries);
    }
    die "Couldn't search" unless loaded;

    my $found_str = grab '#resultsReturned', 'text';
    if ($found_str =~ m/(\d+) results were found, (\d+) returned/) {
        my ($total, $returned) = ($1, $2);
        unless ($total == $returned) {
            die "Searched for $search, got $returned of $total";
        }
        return if $total == 0;

        my $results = grab '.blackborder div', {text => 'text' };
        if (@$results == $total*2) {
            warn "Found $total results\n";
        }
        else {
            die "Not sure what I found searching for '$search' (expected $total): " . Dumper $results;
        }

        for my $r (grep {$_->text =~ m/^\s*\d+\.\s/} @$results) {
            # 1. ABBOTSFORD CHAMBER OF COMMERCE Status: Active  Corporation Number: 000100-7   Business Number: 106679285RC0001
            # 2. AJAX-PICKERING BOARD OF TRADE Status: Active  Corporation Number: 000103-1   Business Number: Not Available

            unless ($r->text =~ m/^\s*\d+\.\s+(.+?)\s+Status:\s+(.+?)\s+Corporation Number:\s+(\S+)\s+Business Number:\s+(?:(\w+)|Not Available)\s*$/) {
                warn "Couldn't understand " . $r->text;
                next;
            }
            my ($name, $status, $corp_number, $bus_number) = ($1, $2, $3, $4);
            if ($data->{$corp_number}) {
                warn "DUP $corp_number - $name\n";
                next;
            }
            warn "GOT $corp_number - $name\n";
            $csv->print($wfh, [$corp_number, $name, $status, $bus_number]);
            $data->{$corp_number}++;
        }
    }
}


sub load_data {
    my $file = shift;
    return {} unless -e $file;

    warn "Reading existing company records into memory from $file ...\n";
    my $csv = Text::CSV_XS->new or die "Can't create a new csv";
    open my $fh, "<:encoding(utf8)", $file;
    my %data;
    my $count = 0;
    while (my $row = $csv->getline($fh)) {
        my $num = $row->[0];
        warn "Found dup: $num" if $data->{$num};
        $data{$num}++;
        $count++;
    }
    $csv->eof or $csv->error_diag();
    warn "Read $count saved entries.\n";
    return \%data;
}
