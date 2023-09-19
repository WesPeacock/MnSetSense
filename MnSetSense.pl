#!/usr/bin/perl
# You should probably use the related bash script to call this script, but you can use: 
my $USAGE = "Usage: $0 [--configfile MnSetSense.ini] [--section MnSetSense] [--debug] [--checkini]";
# debug -- dump debugging information
# checkini -- quit after processing configfile

use 5.020;
use strict;
use warnings;
use English;
use Data::Dumper qw(Dumper);
use utf8;

use open qw/:std :utf8/;
use XML::LibXML;

use File::Basename;
my $scriptname = fileparse($0, qr/\.[^.]*/); # script name without the .pl

use Getopt::Long;
GetOptions (
	'configfile:s'   => \(my $configfile = "$scriptname.ini"), # ini filename
	'section:s'   => \(my $inisection = "MnSetSense"), # section of ini file to use
	'debug'       => \(my $debug = 0),
	'checkini'       => \(my $checkini = 0),
	) or die $USAGE;

use Config::Tiny;
 # ; MnSetSense.ini file looks like:
 # [MnSetSense]
 # FwdataIn=FwProject-before.fwdata
 # FwdataOut=FwProject.fwdata
 # MnSenseMarker=mnsn
 # LogFile=MnSetSense-log.txt

my $config = Config::Tiny->read($configfile, 'crlf');

die "Couldn't find the INI file:$configfile\nQuitting" if !$config;
my $infilename = $config->{$inisection}->{FwdataIn};
my $outfilename = $config->{$inisection}->{FwdataOut};
my $logfilename = $config->{$inisection}->{LogFile};
my $mnsensemkr = $config->{$inisection}->{MnSenseMarker};

my $lockfile = $infilename . '.lock' ;
die "A lockfile exists: $lockfile\
Don't run $0 when FW is running.\
Run it on a copy of the project, not the original!\
I'm quitting" if -f $lockfile ;

open(LOGFILE, '>:encoding(UTF-8)', "$logfilename");

say STDERR "config:". Dumper($config) if $checkini;

say STDERR "Loading fwdata file: $infilename";
my $fwdatatree = XML::LibXML->load_xml(location => $infilename);

my %rthash;
foreach my $rt ($fwdatatree->findnodes(q#//rt#)) {
	my $guid = $rt->getAttribute('guid');
	$rthash{$guid} = $rt;
	}
my @mnsnentry = $fwdatatree->findnodes(q#//*[contains(., '\\# . $mnsensemkr . q# ')]/ancestor::rt#);
say LOGFILE "Searching $infilename for entries containing \\", $mnsensemkr, ", found ", scalar @mnsnentry, " records";
say LOGFILE '';
my $mnsncount = 0;
foreach my $sertnode (@mnsnentry) {
	print LOGFILE "Examining Complex Form: ", displaylexentstring($sertnode);
	my $ImportResText = ($sertnode->findnodes('./ImportResidue/Str'))[0]->to_literal();
	$ImportResText =~ s/\n//g;
	say LOGFILE " ResidueText:", $ImportResText;
	$ImportResText =~ m/\\$mnsensemkr ([0-9]+)/;
	my $mnsenseno = $1;
	if (! $mnsenseno) {
		say LOGFILE "Error: Residue Text has no number in the sense number field:";
		next;
		}
	say LOGFILE "In the Main Entry, will look for sense number:", $mnsenseno;
	# get the rt of the EntryRef contained in the Subentry node
	my $SEentryrefrt = $rthash{$sertnode->findvalue('./EntryRefs/objsur/@guid')};
	say STDERR "Before EntryRef:", $SEentryrefrt if $debug;
	my ($cl) = $SEentryrefrt->findnodes('./ComponentLexemes/objsur') ;
	say qq(cl: $cl) if $debug;
	my $MainLexrt = $rthash{$cl->findvalue('./@guid')};
	if ($MainLexrt->getAttribute('class') ne 'LexEntry') {
		say LOGFILE "Error: Ignoring Subentry because Component was not at the Entry level" ;
		say LOGFILE "Found ", $MainLexrt->getAttribute('class');
		next;
		}
	say LOGFILE "Main Entry found:", displaylexentstring($MainLexrt) if $debug;
	my @senses = $MainLexrt->findnodes('./Senses/objsur');
	my $sensecount = scalar @senses;
	if ($sensecount < $mnsenseno) {
		say LOGFILE "Error: Ignoring Subentry because main entry has only $sensecount senses" ;
		next;
		}
	my $senseguid = $senses[$mnsenseno-1]->getAttribute('guid');
	say STDERR qq(Main sense# $mnsenseno guid ="$senseguid") if $debug;
	my @lexemelist = $SEentryrefrt->findnodes('./ComponentLexemes/objsur');
	say STDERR qq(Component Lexemes count: ), scalar @lexemelist if $debug;
	my ($cl1) = @lexemelist;
	say STDERR  qq(1st Component Lexeme:$cl1)  if $debug;
	$cl1->setAttribute('guid',"$senseguid");
	@lexemelist = $SEentryrefrt->findnodes('./PrimaryLexemes/objsur');
	say STDERR qq(Primary Lexemes count:), scalar @lexemelist if $debug;
	($cl1) = @lexemelist;
	say STDERR  qq(1st Primary Lexeme:$cl1)  if $debug;
	$cl1->setAttribute('guid',"$senseguid");
	@lexemelist = $SEentryrefrt->findnodes('./ShowComplexFormsIn/objsur');
	say STDERR qq(Lexemes count:), scalar @lexemelist if $debug;
	($cl1) = @lexemelist;
	say STDERR  qq(1st ShowComplexFormsIn Lexeme:$cl1)  if $debug;
	$cl1->setAttribute('guid',"$senseguid");

	say STDERR "After EntryRef:", $SEentryrefrt if $debug;
	$mnsncount++;
	say LOGFILE "ComponentLexemes, PrimaryLexemes,  & ShowComplexFormsIn fields changed to the sense number $mnsenseno";
	}
my $xmlstring = $fwdatatree->toString;
# Some miscellaneous Tidying differences
$xmlstring =~ s#><#>\n<#g;
$xmlstring =~ s#(<Run.*?)/\>#$1\>\</Run\>#g;
$xmlstring =~ s#/># />#g;
say LOGFILE '';
say LOGFILE "Finished processing, writing modified  $outfilename" ;
say "Finished processing, writing modified $outfilename" ;
open my $out_fh, '>:raw', $outfilename;
print {$out_fh} $xmlstring;


# Subroutines
sub rtheader { # dump the <rt> part of the record
my ($node) = @_;
return  ( split /\n/, $node )[0];
}

sub traverseuptoclass { 
	# starting at $rt
	#    go up the ownerguid links until you reach an
	#         rt @class == $rtclass
	#    or 
	#         no more ownerguid links
	# return the rt you found.
my ($rt, $rtclass) = @_;
	while ($rt->getAttribute('class') ne $rtclass) {
#		say ' At ', rtheader($rt);
		if ( !$rt->hasAttribute('ownerguid') ) {last} ;
		# find node whose @guid = $rt's @ownerguid
		$rt = $rthash{$rt->getAttribute('ownerguid')};
	}
#	say 'Found ', rtheader($rt);
	return $rt;
}

sub displaylexentstring {
my ($lexentrt) = @_;

my ($formguid) = $lexentrt->findvalue('./LexemeForm/objsur/@guid');
my $formrt =  $rthash{$formguid};
my ($formstring) =($rthash{$formguid}->findnodes('./Form/AUni/text()'))[0]->toString;
# If there's more than one encoding, you only get the first

my ($homographno) = $lexentrt->findvalue('./HomographNumber/@val');

my $guid = $lexentrt->getAttribute('guid');
return qq#$formstring # . ($homographno ? qq#hm:$homographno #  : "") . qq#(guid="$guid")#;
}
