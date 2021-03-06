#!/usr/bin/perl -w

use strict;

use Text::CSV;
use Data::Dumper;
use Log::Dispatch;
use Getopt::Long::Descriptive qw( describe_options prog_name );
use File::Temp qw/ tempfile tempdir /;
use DateTime;
use YAML::Syck qw( LoadFile );

my $progname = $0;

my ($opt, $usage) = describe_options(
    '%c %o <some-arg>',
    [ 'input=s', 'Filename of csv file', { required => 1 } ],
    [ 'config=s', 'Configuration directory', { required => 1 }],
    [ 'koha-upload', 'Filename refers to koha uploaded file' ],
    [ 'columndelimiter=s', 'column delimiter' ],
    [ 'rowdelimiter=s',  'row delimiter' ],
    [ 'encoding=s',  'character encoding',      { default => 'utf8' } ],
    [ 'quote=s',  'quote character', { default => undef } ],
    [ 'escape=s', 'escape character', { default => undef } ],
    [ 'use-bom', 'Use File::BOM', { default => 0 } ],
    [ 'matchpoint', 'Matchpoint for updating existing borrowers.', { default => 'userid' } ],
    [ 'do-import', 'Perform actual import.  This flag is used internally when calling this script recursively.', {default => 0}],
    [ 'logfile=s', 'Log file' ],
    [ 'loglevel=s', 'Log level', { default => 'warning', callbacks => {
	'is loglevel' => sub {
	    return grep {$_[0] eq $_} ('debug', 'info', 'notice', 'warning', 'error', 'critical', 'alert','emergency')
	}
				 }
      }],
    [],
    [ 'verbose|v',  "print extra stuff"            ],
    [ 'help',       "print usage message and exit", { shortcircuit => 1 } ]
    );

binmode STDOUT, ":utf8";

if ($opt->koha_upload) {
    use Koha::UploadedFiles;
    use C4::Auth;
}

if ($opt->help) {
    print STDERR $usage->text;
    exit 0;
}

if ($opt->use_bom) {
    use File::BOM qw();
}

my $logger_outputs = [];

if ( defined($opt->logfile) ) {
    push @$logger_outputs, [ 'File', 'min_level' => $opt->loglevel, 'filename' => $opt->logfile, 'newline' => 1, 'mode' => '>>' ];
}
if ( -t STDOUT ) {
    push @$logger_outputs, [ 'Screen', 'min_level' => $opt->loglevel, 'newline' => 1 ];
}
push @$logger_outputs, [
    'Syslog',
    'min_level' => $opt->loglevel,
    ident => 'borrower-import',
    facility => 'local0'
];

my $log = Log::Dispatch->new( outputs => $logger_outputs );
$log->debug('Initated logger');

local $SIG{__WARN__} = sub {
    my $warning = shift;
    $log->debug($warning);
};

my $tmpdir;
my $date_renewed;
my %column_map;
my %index_map = ();
my %instance_map;
my @extra_fields;
my @header_row;
my $upload;
my $config_dir = $opt->config;
my $instance_map;
if ( -f $config_dir . '/borrowerimport-instance-map.yaml' ) {
    print STDERR "Loading instance-map.yaml\n" if $opt->verbose;
    $instance_map = LoadFile( $config_dir . '/borrowerimport-instance-map.yaml' );
}

sub input {
    if ($opt->koha_upload) {
	$upload = Koha::UploadedFiles->find({ 'uploadcategorycode' => 'BORROWERS',
						     'filename' => $opt->input });

	if (!defined $upload) {
	    $log->info('File has not been uploaded, nothing to do!');
	    exit 0;
	}
	my $patron = Koha::Patrons->find({ 'borrowernumber' => $upload->owner });
	if (!C4::Auth::haspermission($patron->userid, { 'borrowers' => 'edit_borrowers' })) {
	    $log->error('Uploading borrower does not have permissions to edit borrowers');
	    die 'Uploading borrower does not have permissions to edit borrowers';
	}
	return $upload->full_path;
    } else {
	return $opt->input;
    }
}

sub b {
    my ($instance, $branchcode) = @_;
    my ($fh, $filename) = tempfile( "import_${instance}_XXXXXX", DIR => $tmpdir );
    binmode( $fh, ":" . $opt->encoding );
    return {
	'instance' => $instance,
	'branchcode' => $branchcode,
	'tmpfh' => $fh,
        'tmpfilename' => $filename
    };
}	    

if (!$opt->do_import) {
    $date_renewed = DateTime->now->strftime('%F');

    my $TMPDIR = defined $ENV{TMPDIR} ? $ENV{TMPDIR} : '/tmp';

    if ($opt->loglevel eq 'debug') {
	$tmpdir = tempdir( $TMPDIR . '/borrower-importXXXXXX' );
	$log->debug("tmpdir is '$tmpdir'");
    } else {
	$tmpdir = tempdir( $TMPDIR . '/borrower-importXXXXXX',  CLEANUP => 1 );
    }

    
    chmod 0755, $tmpdir;

    %instance_map = ();

    for my $k (keys %$instance_map) {
	$instance_map{$k} = b($instance_map->{$k}->{instance}, $instance_map->{$k}->{branchcode});
    }

    $log->debug(Dumper(\%instance_map));

    %column_map = (
	branchcode      => branchcode(),
	categorycode    => id(),
	cardnumber      => id(),
	userid          => id(),
	surname         => id(),
	firstname       => id(),
	address         => id(),
	address2        => id(),
	zipcode         => id(),
	city            => id(),
	country         => id(),
	phone           => id(),
	B_address       => id(),
	B_address2      => id(),
	B_zipcode       => id(),
	B_city          => id(),
	B_country       => id(),
	B_phone         => id(),
	email           => id(),
	patron_attributes => id(),
	date_renewed    => date_renewed()
	);

    @header_row = qw(
	branchcode
	categorycode
	cardnumber
	userid
        surname
        firstname
	address
	address2
	zipcode
	city
	country
	phone
	B_address
	B_address2
	B_zipcode
	B_city
	B_country
	B_phone
        email
        patron_attributes
        date_renewed
	);

    @extra_fields = qw( date_renewed );

    my $params ={
	sep_char => $opt->columndelimiter,
    };
    if (defined($opt->quote) && $opt->quote ne '') {
	$params->{quote_char} = $opt->quote;
    }
    if (defined($opt->escape) && $opt->escape ne '') {
	$params->{escape_char} = $opt->escape;
    }
    if ($opt->rowdelimiter) {
	$params->{eol} = $opt->rowdelimiter;
	$/ = $params->{eol};
    } else {
	$params->{eol} = "\r\n";
	$/ = "\r\n";
    }
    my $csv = Text::CSV->new($params);
    my $csv_out = Text::CSV->new({ 'eol' => "\r\n" });
    my $fh;
    my $encoding = $opt->encoding;
    my $input_filename = input();
    my $opensuccess;
    my $input_importing = $input_filename . '.importing';

    unless (-e $input_filename) {
	$log->info("Input file does not exist: " . $input_filename . ".  Nothing to do.");
	exit 0;
    }

    unless (rename $input_filename, $input_importing) {
	$log->emerg("Failed to rename file to '$input_importing'");
	exit 1;
    }

    if ($opt->use_bom) {
	$opensuccess = open $fh, "<:via(File::BOM):encoding($encoding)", $input_importing;
    } else {
	$opensuccess = open $fh, "<:encoding($encoding)", $input_importing;
    }

    unless($opensuccess) {
	my $msg = "Failed to open " . $input_importing . ":  $!";
	$log->emerg($msg);
	exit 1;
    }

    if ($opt->koha_upload) {
	rename $input_importing, $input_filename;
	$upload->delete;
    }
    
    my $columns = $csv->getline( $fh );
    my @columns = map {s/^\W*(.*)\W*$/$1/; $_} @$columns;
    $csv->column_names(@columns);

    my $i = 0;
    for my $c (@columns) {
	$index_map{$c} = $i;
	$i++;
    }
    $index_map{'date_renewed'} = $i;

    for my $i (values %instance_map) {
	$csv_out->print($i->{tmpfh}, \@header_row);
    }

    while (my $row = $csv->getline_hr($fh)) {
	my $branchcode = $row->{branchcode};
	my $instance = $instance_map{$branchcode};
	if (!defined $instance) {
	    $log->error("No instance defined for $branchcode");
	    next;
	}
	$csv_out->print($instance->{tmpfh}, process_row($row));
    }

    for my $i (values %instance_map) {

	$i->{tmpfh}->flush();

	my $uid = getpwnam $i->{instance} . '-koha';
	my $gid = getgrnam $i->{instance} . '-koha';
	unless (chown $uid, $gid, $i->{tmpfh}) {
	    $log->error("Couldn't change owner of '" . $i->{tmpfilename} . " to '$uid' '$gid'");
	}

	$log->info("Importing borrowers to " . $i->{instance});
	
	system "sudo /usr/sbin/koha-shell -c 'perl \"$progname\" --do-import --input \"" .
	    $i->{tmpfilename} . "\" --config \"" . $opt->config . "\" --loglevel \"" .
	    $opt->loglevel . "\"' '" . $i->{instance} . "'";
	if ($? != 0) {
	    $log->error("Child process for " . $i->{instance} . " failed with status $?");
	}
    }

    my $input_done = $input_filename . '.done-' . DateTime->now->strftime('%F %T');
    unless (rename $input_importing, $input_done) {
	$log->error("Failed to rename file to '$input_done'");
	exit 1;
    }
} else {
    require Koha::Patrons::Import;

    my $fh;
    unless (open $fh, "<:encoding(" . $opt->encoding . ")", $opt->input) {
	$log->emerg("Failed to open '" . $opt->input . "': $!");
	exit 1;
    }
    my $params = {
	matchpoint => $opt->matchpoint,
	preserve_extended_attributes => 1,
	overwrite_cardnumber => 1,
	file => $fh,
	defaults => {
	    surname => ''
	}
    };

    my $csv = Text::CSV->new();
    $csv->eol("\r\n");
    local $/ = "\r\n";
    
    my $importer = Koha::Patrons::Import->new(text_csv => $csv);

    my $result = $importer->import_patrons($params);

    for my $error (@{$result->{errors}}) {
	$log->error(serialize($error));
    }

    $log->notice('imported: ' . safestr($result->{imported}) .
		 ' overwritten: ' . safestr($result->{overwritten}) .
		 ' already in db: ' . safestr($result->{alreadyindb}) .
		 ' invalid: ' . safestr($result->{invalid}));

    for my $feedback (@{$result->{feedback}}) {
	$log->info(serialize($feedback));
    }
}

sub safestr {
    my $s = shift;
    return defined $s ? $s : '<undefined>';
}

sub serialize {
    my $hash = shift;

    my $s = '';
    for my $key (keys %$hash) {
	if ($s ne '') {
	    $s .= ', ';
	}
	$s .= "$key : ";
	if (ref $hash->{$key} eq 'ARRAY') {
	    my $first = 1;
	    $s .= "[";
	    for my $v (@{$hash->{$key}}) {
		if ($first) {
		    $first = 0;
		} else {
		    $s .= ', ';
		}
		if (ref $v eq 'HASH') {
		    $s .= "{";
		    $s .= serialize($v);
		    $s .= "}";
		} else {
		    $s .= $v;
		}
	    }
	    $s .= "]";
	} elsif (ref $hash->{$key} eq 'HASH') {
	    $s .= "{";
	    $s .= serialize($hash->{$key});
	    $s .= "}";
	} else {
	     $s .= $hash->{$key};
	}
    }

    return $s;
}

sub id {
    my $index = shift;

    return sub {
	my $val = shift;
	my $key = shift;
	if (!defined $index) {
	    $index = $index_map{$key};
	}
	return [{val => $val, index => $index}];
    };
}

sub branchcode {
    my $index = shift;
    return sub {
	my $val = shift;
	my $key = shift;
	if (!defined $index) {
	    $index = $index_map{$key};
	}
	return [{val => $instance_map{$val}->{branchcode}, index => $index}];
    };
}

sub date_renewed {
    my $index = shift;

    return sub {
	if (!defined $index) {
	    $index = $index_map{'date_renewed'};
	}
	return [{val => $date_renewed, index => $index}];
    };
}

sub patron_attribute {
    my $index = shift;

    return sub {
	my $val = shift;

	my $s = '';
	for my $attr (split(',', $val, -1)) {
	    my @pair = split(':', $attr, -1);
	    if (scalar(@pair) != 2) {
		$log->error("Invalid attribute: $val");
		next;
	    }
	    if ($pair[0] eq 'klass') {
		$pair[0] = 'Klass';
	    }
	    $s .= $pair[0] . ':' . $pair[1];
	}
	return [{val => $s, index => $index}];
    }
}

sub process_row {
    my $row = shift;

    my @prow = (undef) x scalar(keys %column_map);

    for my $key (keys %$row) {
	my $mapping = $column_map{$key};

	if (!defined $mapping) {
	    $log->emerg("Invalid column name: '$key'");
	    exit 1;
	}

	my $res = $mapping->($row->{$key}, $key);

	for my $r0 (@$res) {
	    $prow[$r0->{index}] = $r0->{val};
	}
    }

    for my $key (@extra_fields) {
	my $mapping = $column_map{$key};

	if (!defined $mapping) {
	    $log->alert("Invalid column name: '$key'");
	    exit 1;
	}

	my $res = $mapping->();

	for my $r0 (@$res) {
	    $prow[$r0->{index}] = $r0->{val};
	}
    }

    return \@prow;
}
