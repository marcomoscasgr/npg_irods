package WTSI::NPG::HTS::TreePublisher;

use namespace::autoclean;
use Data::Dump qw[pp];
use File::Basename;

use File::Spec::Functions qw[catfile abs2rel];
use Moose;
use MooseX::StrictConstructor;
use WTSI::DNAP::Utilities::Params qw[function_params];
use WTSI::NPG::HTS::BatchPublisher;
use WTSI::NPG::HTS::PublishState;

use JSON;
use Readonly;

with qw[
         WTSI::DNAP::Utilities::Loggable
         WTSI::NPG::HTS::RunPublisher
         WTSI::NPG::HTS::PathLister
       ];

our $VERSION = '';
Readonly::Scalar my $JSON_FILE_VERSION => '1.1';

has 'obj_factory' =>
    (does          => 'WTSI::NPG::HTS::DataObjectFactory',
     is            => 'ro',
     required      => 1,
     lazy          => 1,
     builder       => '_build_obj_factory',
     documentation => 'A factory building data objects from files. ' .
                      'Defaults to WTSI::NPG::HTS::DefaultDataObjectFactory');

has 'force' =>
  (isa           => 'Bool',
   is            => 'ro',
   required      => 0,
   default       => 0,
   documentation => 'Force re-publication of files that have been published');

has 'max_errors' =>
  (isa           => 'Int',
   is            => 'ro',
   required      => 0,
   predicate     => 'has_max_errors',
   documentation => 'The maximum number of errors permitted per call to ' .
                    'publish_tree before the remainder of its operation ' .
                    'is aborted');

has 'publish_state' =>
  (isa           => 'WTSI::NPG::HTS::PublishState',
   is            => 'ro',
   required      => 1,
   builder       => '_build_publish_state',
   lazy          => 1,
   documentation => 'State of all files published, across all batches');

has 'require_checksum_cache' =>
    (is            => 'ro',
     isa           => 'ArrayRef[Str]',
     required      => 1,
     default       => sub { return [qw[bam cram]] },
     documentation => 'A list of file suffixes for which MD5 cache files ' .
                      'must be provided and will not be created on the fly');

has 'mlwh_json' =>
  (isa           => 'Str',
  is             => 'ro',
  required       => 0,
  predicate     => 'has_mlwh_json',
  documentation  => 'The json file to which information about the irods collection ' .
                    'folder will be added. Cannot be used with mlwh_json_cb defined.');

=head2 publish_tree

  Arg [1]    : File batch, ArrayRef[Str].

  Named args : primary_cb
               Callback returning primary AVUs for a data object. CodeRef.
               Optional.

               secondary_cb
               Callback returning secondary AVUs for a data object. CodeRef.
               Optional.

               extra_cb
               Callback returning extra AVUs for a data object. CodeRef.
               Optional.

               filter
               Function returning true for each file path to be published.
               CodeRef. Optional.

               mlwh_json_cb
               Callback writing information about data objects to a JSON file.
               CodeRef. Optional. Cannot be used with the mlwh_json attribute set.
               The mlwh_json_cb is deprecated and will be removed once the
               illumina code is refactored to use the LocationWriter.

  Example    : my ($num_files, $num_processed, $num_errors) =
                 $pub->publish_tree($files,
                                    primary_cb   => sub { ... },
                                    secondary_cb => sub { ... });

  Description: Publish set of files from the publisher's source directory
               to its iRODS destination collection while retaining any
               subdirectory structure present under the source directory,
               creating new iRODS collections as required. The AVU callbacks
               are used to attach any metadata.

               Each callback must expect a single WTSI::NPG::iRODS::DataObject
               argument to whose AVU API may be used to attach metadata during
               publishing.
  Returntype : Array[Int]

=cut

{
  my $positional = 2;
  my @named      = qw[primary_cb secondary_cb extra_cb filter mlwh_json_cb];
  my $params     = function_params($positional, @named);

  sub write_json {
    my ($self) = @_;
    my ($json_fh, $json_hash);
    open $json_fh, '>:encoding(UTF-8)', $self->mlwh_json or
      self->logconfess(q[could not open ml warehouse json file] .
      qq[$self->mlwh_json]);
    $json_hash = {
      version  => $JSON_FILE_VERSION,
      irods_collection => $self->dest_collection
    };
    print $json_fh encode_json($json_hash) or
      self->logconfess(q[could not write to ml warehouse json file ] .
      qq[$self->mlwh_json]);

    close $json_fh or
      self->logconfess(q[could not close ml warehouse json file] .
      qq[$self->mlwh_json]);
    return 1;
  }

  sub publish_tree {
    my ($self, $files) = $params->parse(@_);

    if ($self->has_mlwh_json && defined $params->mlwh_json_cb) {
      $self->logconfess('The mlwh_json_cb cannot be defined with the mlwh_json attribute set');
    }
    if (defined $params->filter) {
      ref $params->filter eq 'CODE' or
          $self->logconfess('The filter argument must be a CodeRef');
      my $fn = $params->filter;

      my $fnlog = sub {
        my ($file) = @_;

        if ($fn->($file)) {
          $self->debug("Publish filter true (accepted) for '$file'");
          return 1;
        }

        $self->info("Publish filter false (rejected) for '$file'");
        return 0;
      };

      $files = [grep { $fnlog->($_) } @{$files}];
    }

    $self->_ensure_coll_exists($self->dest_collection);

    my $collated_by_dest = $self->_collate_by_dest_coll($files);

    my ($num_files, $num_processed, $num_errors) = (0, 0, 0);
    DEST:
    foreach my $dest_coll (sort keys %{$collated_by_dest}) {
      $self->_ensure_coll_exists($dest_coll);

      my $subset = $collated_by_dest->{$dest_coll};

      $self->debug("Publishing batch to '$dest_coll': ", pp($subset));

      my @init_args =
          (force                  => $self->force,
           irods                  => $self->irods,
           obj_factory            => $self->obj_factory,
           publish_state          => $self->publish_state,
           require_checksum_cache => $self->require_checksum_cache);

      if ($self->has_max_errors) {
        if ($num_errors >= $self->max_errors) {
          $self->error("The number of errors $num_errors reached the maximum ",
                       'permitted of ', $self->max_errors, '. Aborting');
          last DEST;
        }
        else {
          my $batch_max_errors = $self->max_errors - $num_errors;
          push @init_args, max_errors => $batch_max_errors;
        }
      }

      my $batch_publisher = WTSI::NPG::HTS::BatchPublisher->new(@init_args);
      my ($nf, $np, $ne)  =
          $batch_publisher->publish_file_batch
              ($subset, $dest_coll,
               primary_cb   => $params->primary_cb,
               secondary_cb => $params->secondary_cb,
               extra_cb     => $params->extra_cb,
               mlwh_json_cb => $params->mlwh_json_cb);
      $num_files     += $nf;
      $num_processed += $np;
      $num_errors    += $ne;
    }

    if ($self->has_mlwh_json) {
      $self->write_json();
    }

    return ($num_files, $num_processed, $num_errors);
  }
}

# Collate files into batches, one batch per destination collection
sub _collate_by_dest_coll {
  my ($self, $files) = @_;

  my %collated_by_dest;
  foreach my $file (@{$files}) {
    my $dest_coll = $self->_infer_dest_coll($file);
    $collated_by_dest{$dest_coll} ||= [];
    push @{$collated_by_dest{$dest_coll}}, $file;
  }

  return \%collated_by_dest;
}

# Return a destination collection for a file. The path of the file
# relative to the source directory is used to determine the path of
# the data object in iRODS relative to the specified target
# collection.
sub _infer_dest_coll {
  my ($self, $path) = @_;

  my $local_rel  = abs2rel($path, $self->source_directory);
  my $remote_abs = catfile($self->dest_collection, $local_rel);
  my ($obj_name, $dest_coll) = fileparse($remote_abs);
  $self->debug("Destination collection of '$path' is '$dest_coll'");

  return $dest_coll;
}

sub _ensure_coll_exists {
  my ($self, $coll) = @_;
  if (not $self->irods->is_collection($coll)) {
    $self->irods->add_collection($coll);
  }

  return $coll;
}

sub _build_obj_factory {
  my ($self) = @_;

  return WTSI::NPG::HTS::DefaultDataObjectFactory->new(irods => $self->irods)
}

sub _build_publish_state {
  my ($self) = @_;

  return WTSI::NPG::HTS::PublishState->new;
}

__PACKAGE__->meta->make_immutable;

no Moose;

1;

__END__

=head1 NAME

WTSI::NPG::HTS::TreePublisher

=head1 DESCRIPTION

A publisher that reads files from a local source directory tree and writes
them to a remote iRODS destination collection tree with the same structure.

=head1 AUTHOR

Keith James <kdj@sanger.ac.uk>

=head1 COPYRIGHT AND DISCLAIMER

Copyright (C) 2019, 2021 Genome Research Limited. All Rights Reserved.

This program is free software: you can redistribute it and/or modify
it under the terms of the Perl Artistic License or the GNU General
Public License as published by the Free Software Foundation, either
version 3 of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

=cut
