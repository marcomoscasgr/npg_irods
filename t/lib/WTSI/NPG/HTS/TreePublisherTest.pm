package WTSI::NPG::HTS::TreePublisherTest;

use strict;
use warnings;

use English qw[-no_match_vars];
use File::Basename;
use File::Spec::Functions qw[abs2rel catfile];
use Log::Log4perl;
use Test::More;

use base qw[WTSI::NPG::HTS::Test];

use WTSI::NPG::HTS::TreePublisher;
use WTSI::NPG::iRODS;

use JSON;
use Readonly;

Log::Log4perl::init('./etc/log4perl_tests.conf');

my $pid          = $PID;
my $test_counter = 0;
my $data_path    = 't/data';

my $irods_tmp_coll;

sub setup_test : Test(setup) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);

  $irods_tmp_coll =
    $irods->add_collection("TreePublisherTest.$pid.$test_counter");
  $test_counter++;
}

sub teardown_test : Test(teardown) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);
  $irods->remove_collection($irods_tmp_coll);
}

sub publish_tree : Test(59) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);
  my $source_path = "$data_path/treepublisher";

  my $pub = WTSI::NPG::HTS::TreePublisher->new
    (irods            => $irods,
     source_directory => $source_path,
     dest_collection  => $irods_tmp_coll);

  my $obj_factory = WTSI::NPG::HTS::DefaultDataObjectFactory->new
    (irods => $pub->irods);

  my @files = grep { -f } $pub->list_directory($source_path, recurse => 1);

  my $primary_avus = sub {
    return ({attribute => 'primary', value => 'pvalue'})
  };
  my $secondary_avus = sub {
    return ({attribute => 'secondary', value => 'svalue'})
  };
  my $extra_avus = sub {
    return ({attribute => 'extra', value => 'evalue'})
  };

  my $mlwh_json_filename = qq[metadata.json];
  my $mlwh_json_cb = sub {
    # DataObject, path to file folder, collection file
    my ($obj, $collection, $file) = @_;
      if (defined $mlwh_json_filename) { 
        Readonly::Scalar my $JSON_FILE_VERSION => '1.0';
        my $mlwh_hash = {
          irods_root_collection    => $collection,
          irods_data_relative_path => $file
        };
        my ($json_fh, $json_hash);
        if (-e $mlwh_json_filename) {
          open $json_fh, '+<:encoding(UTF-8)', $mlwh_json_filename or
            self->logcroak(q[could not open ml warehouse json file] .
            qq[$mlwh_json_filename]);
          $json_hash = decode_json <$json_fh>;
        }
        else {
          open $json_fh, '>:encoding(UTF-8)', $mlwh_json_filename or
            self->logcroak(q[could not open ml warehouse json file] .
            qq[$mlwh_json_filename]);
          $json_hash = {
            version  => $JSON_FILE_VERSION,
            irods_top_collection_folder => $irods_tmp_coll,
            products => [],
          };
        }
        push @{$json_hash->{products}}, $mlwh_hash;

        seek $json_fh, 0, 0;

        print $json_fh encode_json($json_hash) or
          self->logcroak(q[could not write to ml warehouse json file ] .
          qq[$mlwh_json_filename]);

        close $json_fh or
          self->logcroak(q[could not close ml warehouse json file] .
          qq[$mlwh_json_filename]);
      }
      return 1;
    };

  my ($num_files, $num_processed, $num_errors) =
      $pub->publish_tree(\@files,
                         primary_cb   => $primary_avus,
                         secondary_cb => $secondary_avus,
                         extra_cb     => $extra_avus,
                         mlwh_json_cb => $mlwh_json_cb);

  my $num_expected = scalar @files;
  cmp_ok($num_errors,    '==', 0, 'No errors on publishing');
  cmp_ok($num_files, '==', $num_expected,
         'Found the expected number of files');
  cmp_ok($num_processed, '==', $num_expected,
         'Published the expected number of files');

  my @observed_paths = observed_data_objects($irods, $irods_tmp_coll,
                                             $irods_tmp_coll);
  my @expected_paths =('a/x/1.txt',
                       'a/x/2.txt',
                       'a/y/3.txt',
                       'a/y/4.txt',
                       'a/z/5.txt',
                       'a/z/6.txt',
                       'b/x/1.txt',
                       'b/x/2.txt',
                       'b/y/3.txt',
                       'b/y/4.txt',
                       'b/z/5.txt',
                       'b/z/6.txt',
                       'c/x/1.txt',
                       'c/x/2.txt',
                       'c/y/3.txt',
                       'c/y/4.txt',
                       'c/z/5.txt',
                       'c/z/6.txt');

  is_deeply(\@observed_paths, \@expected_paths,
            'Published correctly named files') or
              diag explain \@observed_paths;

  check_metadata($irods, map { catfile($irods_tmp_coll, $_) } @observed_paths);

  ok(-e $mlwh_json_filename, "File json in public_tree correctly created");
}

sub publish_tree_filter : Test(4) {
  my $irods = WTSI::NPG::iRODS->new(environment          => \%ENV,
                                    strict_baton_version => 0);
  my $source_path = "$data_path/treepublisher";

  my $pub = WTSI::NPG::HTS::TreePublisher->new
      (irods            => $irods,
       source_directory => $source_path,
       dest_collection  => $irods_tmp_coll);

  my $obj_factory = WTSI::NPG::HTS::DefaultDataObjectFactory->new
      (irods => $pub->irods);

  my @files = grep { -f } $pub->list_directory($source_path, recurse => 1);

  my ($num_files, $num_processed, $num_errors) =
      $pub->publish_tree(\@files,
                        filter => sub {
                          my ($f) = @_;
                          my ($n) = $f =~ m{(\d)[.]txt$}; # parse digit
                          # Return true (i.e. pass/include) for even numbers
                          return $n % 2 == 0;
                        });

  my $num_expected = 9;
  cmp_ok($num_errors,    '==', 0, 'No errors on publishing');
  cmp_ok($num_files, '==', $num_expected,
         'Found the expected number of files');
  cmp_ok($num_processed, '==', $num_expected,
         'Published the expected number of files');

  my @observed_paths = observed_data_objects($irods, $irods_tmp_coll,
                                             $irods_tmp_coll);
  my @expected_paths =('a/x/2.txt',
                       'a/y/4.txt',
                       'a/z/6.txt',
                       'b/x/2.txt',
                       'b/y/4.txt',
                       'b/z/6.txt',
                       'c/x/2.txt',
                       'c/y/4.txt',
                       'c/z/6.txt');

  is_deeply(\@observed_paths, \@expected_paths,
            'Published correctly filtered files') or
      diag explain \@observed_paths;
}

sub observed_data_objects {
  my ($irods, $dest_collection, $root_collection) = @_;

  my ($observed_paths) = $irods->list_collection($root_collection, 'RECURSE');
  my @observed_paths = @{$observed_paths};
  @observed_paths = sort @observed_paths;
  @observed_paths = map { abs2rel($_, $root_collection) } @observed_paths;

  return @observed_paths;
}

sub check_metadata {
  my ($irods, @paths) = @_;

  foreach my $path (@paths) {
    my $obj = WTSI::NPG::HTS::DataObject->new($irods, $path);
    my $file_name = fileparse($obj->str);

    my %attrs = ('primary'   => 'pvalue',
                 'secondary' => 'svalue',
                 'extra'     => 'evalue');

    while (my ($attr, $value) = each %attrs) {
      ok($obj->get_avu($attr, $value), "$path has AVU '$attr' => '$value'");
    }
  }
}

1;
