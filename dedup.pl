#!/usr/bin/perl

use v5.20;
use warnings;
use strict;
use feature 'switch';

use Getopt::Long;
use Digest::MD5;
use Term::ReadLine;
use File::Spec;
use File::Path qw( rmtree make_path );

use constant {
	CLEAR_LINE	=> "\x1B[2K\x1B[G",
	CACHE_DIR	=> '._dedup_checksum_cache',
};

=head1 dedup.pl

This is a portable script for managing large and unorganized collections of files. It has features to help deduplicate files with identical content.

=cut

my $term = Term::ReadLine->new('dedup');

sub hash_content($) {
	die "Invalid file: $_" unless (-r $_);

	open my $fh, '<', $_ or die "Cannot open $_: $!";
	binmode $fh;

	my $test;
	#read $fh, $test, 10 or die "Cannot read file: $!";

	my $result = Digest::MD5->new->addfile($fh)->hexdigest;

	close $fh;

	return $result;
}

sub cache_checksum($$$) {
	my ($path, $filename, $checksum) = @_;
	my $cache_path = CACHE_DIR . '/' . $path;
	my $cache_link = "$cache_path/$filename";
	make_path($cache_path);
	if (-l $cache_link) {
		unless (unlink $cache_link) {
			warn "Cannot delete symlink: $!";
			return;
		}
	}
	symlink($checksum, $cache_link) or warn "Failed to create symlink: $!";
}

sub indirect_recursion {
	return walk_dir(shift, shift, @_);
}

sub walk_dir(&$@) {
	my $callback = shift;
	my $base_dir = shift;
	my %options = @_;
	my @subdirs;
	my $count_files = 0;

	print "Checking dir: $base_dir\n" if ($options{'display'});

	$base_dir =~ s/([\[\]\(\)\s'"])/\\$1/g;

	foreach my $path (glob "$base_dir/*") {
		next if ($path eq '.' || $path eq '..');
		if (-d $path) {
			push @subdirs, $path;
			next;
		}
		print CLEAR_LINE . $path if ($options{'display'});
		local $_ = $path;
		$callback->($_);
		$count_files++;
	}

	print CLEAR_LINE . "$count_files files\n" if ($options{'display'});
	print "\n" if ($options{'display'});

	foreach (@subdirs) {
		indirect_recursion($callback, $_, %options) if (!$options{'callback_dirs'} || $callback->($_));
	}
}

sub choose(&$@) {
	my $callback = shift;
	my $prompt = shift;
	my $i = 0;
	my %choices = map { $i++ => $_ } @_;
	my $response;
	INPUTLOOP: do {
		my $i = 0;
		print join '', map { "\t" . $_ . ': ' . $choices{$_} . "\n" }
		               sort keys %choices;
		$response = $term->readline($prompt);

		#                  1          2
		if ($response =~ /^([a-z]+)\s*([\d\s]*)$/i) {
			local $_ = $1;
			my @resp = grep /\d/, split /\s+/, $2;
			my @indicies = @resp ? @resp : keys %choices;
			my @eliminated = $callback->(\@resp, %choices{@indicies});
			delete @choices{@eliminated};
		} else {
			warn "Unrecognized response" if ($response);
		}
	} while (length $response);
}

sub unit_format($;$) {
	my $qty = shift;
	my $unit = shift;
	my @si_prefix = ('', qw( Ki Mi Gi Ti ));

	while ($qty > 1000) {
		$qty /= 1000;
		shift @si_prefix;
	}

	return sprintf("%0.1f %s%s", $qty, shift @si_prefix, $unit // 'B');
}

$|++;

=head2 OPTIONS

=over 4

=item * C<--base /path/to/dir>

Path to the directory which will be operated on.

=item * C<--dedup>

Find duplicate files under the base directory and prompt the user to decide how to handle each set of duplicates.
Also, creates a hidden cache directory under the base directory to store checksums and speed up future runs.

=item * C<--no-dedup-cache>

Do not create a the dedup checksum cache directory.

=item * C<--rank>

Rank files under the base directory by date modified and size. Present the highest ranking files to the user. By default, older and larger correspond to higher rank.

=item * C<--rank-weight-age X>

Adjust the weight given to a file's last modified date when calculating a file's rank.
Default 1.0.

=item * C<--rank-weight-size X>

Adjust the weight given to file size when calculating a file's rank.
Default 1.0.

=item * C<--help>

Display this help message.

=back

=cut

my $opt_base_dir;
my $opt_dedup;
my $opt_dedup_cache = 1;
my $opt_rank;
my $opt_rank_mode = 'auto';
my $opt_rank_weight_age = 1.0;
my $opt_rank_weight_size = 1.0;
my $opt_help;
GetOptions(
	'base=s'		=> \$opt_base_dir,
	'dedup!'		=> \$opt_dedup,
	'dedup-cache!'		=> \$opt_dedup_cache,
	'rank!'			=> \$opt_rank,
	'rank-mode=s'		=> \$opt_rank_mode,
	'rank-weight-age=f'	=> \$opt_rank_weight_age,
	'rank-weight-size=f'	=> \$opt_rank_weight_size,
	'h|help!'		=> \$opt_help,
);

exec('pod2text', $0) if ($opt_help);

die 'Missing required arg --base' unless ($opt_base_dir);
die "Invalid base dir: $opt_base_dir" unless (-d $opt_base_dir);

warn "Neither --rank nor --dedup selected. Nothing to do." unless ($opt_rank || $opt_dedup);

=head2 --dedup FEATURES

For each set of duplicate files found, the user can choose actions to take. The files are presented in a numbered list, followed by a prompt. The response should be of the form: C<action N N ...>, where C<action> is a letter or word indicating the action and optionally followed by numbers corresponding to files in the list, if needed.

Possible actions are:

=over 4

=item * C<d> or C<rm>

Delete the indicated files. Defaults to no action if no list of files is provided.

=item * C<l> or C<link>

Make indicated files in the list hard links to each other. Defaults to all files if no list of files is provided.

=item * C<m> or C<mv>

Requires exactly two files. Delete the second file and move the first file to the directory that the second file was in.

=item * C<c>

Clear the cache of the indicated files. Defaults to all files if no list of files is provided.

=back

=cut

if ($opt_dedup) {
	make_path(CACHE_DIR) if ($opt_dedup_cache);

	my %unique_content;	# hash => [filenames]
	my %directory_files;	# dir_path => {hashes}
	my %paths_cached;	# {filepath => 1}

	say "Reading cache";
	walk_dir {
		my (undef, $dir_path, $filename) = File::Spec->splitpath($_);

		my $hash;
		unless (-l $_) {
			warn "Non-symlink found in cache dir: $_";
			return;
		}
		unless ($hash = readlink $_) {
			warn "Failed to read symlink: $!";
			return;
		}

		s/^([^\/]+\/)//; # remove CACHE_DIR prefix to convert to original path
		my (undef, $orig_dir_path, undef) = File::Spec->splitpath($_);

		unless (-f $_) {
			unlink CACHE_DIR . "/$_";
			return;
		}

		$paths_cached{$_} = 1;

		my $file_list = $unique_content{$hash} //= [];
		push @$file_list, [$orig_dir_path, $filename];

		my $dir_list = $directory_files{$orig_dir_path} //= {};
		$dir_list->{$hash} = 1;
	} CACHE_DIR;

	say "Traversing tree";
	my $cache_check = CACHE_DIR;
	walk_dir {
		return if (/^$cache_check/o);
		s/^(\.\/)//; # remove leading ./ in path
		return unless (-f $_);
		return if ($paths_cached{$_});

		my (undef, $dir_path, $filename) = File::Spec->splitpath($_);
		my $hash = hash_content($_);

		my $file_list = $unique_content{$hash} //= [];
		push @$file_list, [$dir_path, $filename];

		my $dir_list = $directory_files{$dir_path} //= {};
		$dir_list->{$hash} = 1;

		cache_checksum($dir_path, $filename, $hash) if ($opt_dedup_cache);
	} $opt_base_dir, display => 1;
	say "done";

	print "\n";

	foreach (grep { @$_ > 1 } values %unique_content) {
		print "Duplicate files:\n";
		choose {
			my $response = shift;
			my %chosen = @_;

			when (/^(d|rm?)$/) {
				my @done;
				return @done unless (@$response);
				while (my($index, $file) = each %chosen) {
					#print "Would unlink $file\n";
					say "unlink $file";
					if (unlink $file) {
						push @done, $index;
						unlink CACHE_DIR . "/$file";
					} else {
						warn "Failed to delete $file $!";
					}
				}
				return @done;
			}

			when (/^c$/) {
				while (my($index, $file) = each %chosen) {
					say "clear cache for $file";
					unlink CACHE_DIR . "/$file";
				}
				return ();
			}

			when (/^l(i(nk?)?)?$/) {
				my $selected;
				while (my($index, $copy) = each %chosen) {
					unless ($selected) {
						$selected = $copy;
						next;
					}
					#print "Would unlink $copy and link $selected to $copy\n";
					unlink $copy and link $selected, $copy;
				}
				say "all linked";
				return ();
			}

			when (/^mv?$/) {
				if (@$response != 2) {
					warn "mv requires exactly two choices (mv A --> B)";
					return ();
				}
				my ($src, $dst) = @chosen{@$response};
				my (undef, undef, $dst_filename) = File::Spec->splitpath($src);
				my (undef, $dst_path, undef) = File::Spec->splitpath($dst);
				my $new_dst = "$dst_path$dst_filename";
				if ($src eq $new_dst) {
					warn "No-op mv";
					return ();
				}
				#print "Would unlink $dst and rename $src to $new_dst\n";
				say "unlink $dst and rename $src to $new_dst";
				if (unlink $dst) {
					unless (rename $src, $new_dst) {
						warn "Failed to rename $src to $dst: $!";
					}
					return (@$response);
				} else {
					warn "Failed to delete $dst: $!";
				}
				return ();
			}

			default {
				warn "Unknown action: $_";
				return ();
			}

		} 'Action? (d,l,m,c) ', map { File::Spec->catpath(undef, $_->[0], $_->[1]) } @$_;
		print "\n";
	}
}

=head2 --rank FEATURES

Ranks all files under the base directory and presents the top 25. By default, both larger file size and earlier modified date contribute to higher ranking. Use the C<--rank-weight-*> options to adjust. Weights are in proportion to each other, so e.g. age=1.0 and size=2.0 would result in age having 33% weight and size having 67% weight.

Rank mode may be expanded in the future.

=cut

if ($opt_rank) {
	my $total_est_size = 0;
	my %score_tree;
	my ($age_min, $age_max);
	my ($size_min, $size_max);
	my $weight_sum = abs($opt_rank_weight_age) + abs($opt_rank_weight_size);
	my $weight_age = $opt_rank_weight_age / $weight_sum;
	my $weight_size = $opt_rank_weight_size / $weight_sum;
	printf("Weights: age=%0.3f, size=%0.3f\n", $weight_age, $weight_size);

	my $calc_score = sub {
		my ($size, $age) = @_[7, 9];
		my $norm_size = ($size - $size_min) / $size_max;
		my $norm_age = 1 - ($age - $age_min) / $age_max;
		return $norm_size * $weight_size +
		       $norm_age * $weight_age;
	};

	say "Gathering stats";
	walk_dir {
		return 1 unless (-f $_);
		my @stats = stat $_;
		$score_tree{$_} = \@stats;

		$total_est_size += $stats[7];
		$age_min = $stats[9] if (!$age_min || $age_min > $stats[9]);
		$age_max = $stats[9] if (!$age_max || $age_max < $stats[9]);
		$size_min = $stats[7] if (!$size_min || $size_min > $stats[7]);
		$size_max = $stats[7] if (!$size_max || $size_max < $stats[7]);
	} $opt_base_dir;

	say "Scoring";
	my @score_list;
	while (my ($filepath, $stats) = each %score_tree) {
		push @score_list, [$filepath, $calc_score->(@$stats), $stats];
	}

	say "Sorting";
	@score_list = sort { $b->[1] <=> $a->[1] } @score_list;

	say "Total est size: " . unit_format($total_est_size);
	say "Size range: " . unit_format($size_min) . " - " . unit_format($size_max);
	say "Age range: " . localtime($age_min) . " - " . localtime($age_max);

	say "\nTop 25:";
	foreach (@score_list[0..24]) {
		printf("% 10s %s %s\n", unit_format($_->[2]->[7]), scalar localtime($_->[2]->[9]), $_->[0]);
	}
}

