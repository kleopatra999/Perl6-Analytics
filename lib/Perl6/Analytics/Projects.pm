package Perl6::Analytics::Projects;

use strict;
use warnings;
use Carp qw(carp croak verbose);

use JSON::XS;
use JSON::InFile;
use Git::ClonesManager;

sub new {
	my ( $class, %args )= @_;
	my $self = {
		pr_info => {},
	};
	$self->{vl} = $args{verbose_level} // 3;
	bless $self, $class;
}

sub pr_info {
	my $self = shift;
	return $self->{pr_info};
}

sub projects_base_fpath {
	return 'data/projects-base.json';
}

sub projects_final_fpath {
	return 'data/projects-final.json';
}

sub get_ipos_str {
	my ( $self, $offset ) = @_;
	$offset //= 0;
	my $line = (caller(1+$offset))[2] || 'l';
	my $sub = (caller(2+$offset))[3] || 's';
	return "$sub($line)";
}

sub dump {
	croak "Missing parameter for 'dump'.\n" if scalar @_ < 3;
	my ( $self, $text, $struct, $offset ) = @_;
	unless ( $self->{dumper_loaded} ) {
		require Data::Dumper;
		$self->{dumper_loaded} = 1;
	};

	local $Data::Dumper::Indent = 1;
	local $Data::Dumper::Pad = '';
	local $Data::Dumper::Terse = 1;
	local $Data::Dumper::Sortkeys = 1;
	local $Data::Dumper::Deparse = 1;
	unless ( $text ) {
		print Data::Dumper->Dump( [ $struct ] );
		return;
	}
	print $text . ' on ' . $self->get_ipos_str($offset) . ': ' . Data::Dumper->Dump( [ $struct ] );
}

sub load_base_list {
	my ( $self ) = @_;

	my $projects_db = JSON::InFile->new(fpath => $self->projects_base_fpath, verbose_level => $self->{vl});
	my $projects_info = $projects_db->load();

	# Normalize formating - saved only if changed.
	$projects_db->save($projects_info);

	return $projects_info;
}

sub gcm_obj {
	my ( $self ) = @_;
	$self->{gcm_obj} = Git::ClonesManager->new( verbose_level => $self->{vl} )
		unless $self->{gcm_obj};
	return $self->{gcm_obj};
}

sub git_repo_obj {
	my ( $self, $project_alias, %args ) = @_;
	return $self->gcm_obj->get_repo_obj( $project_alias, %args );
}

sub add_p6_modules {
	my ( $self ) = @_;

	my $skip_fetch = 0;
	$skip_fetch = 1; # speed up debugging a bit
	my $ecos_alias = 'ecosystem';
	my $ecos_fpath = 'META.list';

	croak "Repository with alias '$ecos_alias' not defined.\n"
		unless $self->{pr_info}{$ecos_alias};

	my $ecos_repo_url = $self->{pr_info}{$ecos_alias}{'source-url'};

	my $repo = $self->git_repo_obj($ecos_alias, repo_url => $ecos_repo_url, skip_fetch => $skip_fetch );
	my @modules_meta_urls = $repo->run('show', 'HEAD:'.$ecos_fpath );

	my $mod_base_info = [];
	my $url_prefix = 'https://raw2.github.com';
	foreach my $meta_url ( @modules_meta_urls ) {
		if (
			my (                  $author,  $repo_name, $branch, $meta_fpath ) = $meta_url =~ m{^
				\Q$url_prefix\E / ([^/]+) / ([^/]+) /   ([^/]+) / (.*)
			$}x
		) {
			push @$mod_base_info, {
				author => $author,
				repo_name => $repo_name,
				branch => $branch,
				meta_fpath => $meta_fpath,
			};
		} else {
			croak "Can't parse module meta file url '$meta_url'.\n";
		}
	}
	$self->dump('modules info parsed from ecosystem list', $mod_base_info ) if $self->{vl} >= 8;

	my $json_obj = JSON::XS->new->canonical(1)->pretty(1)->utf8(0)->relaxed(1);

	# ToDo - move to data/projects-skip.json
	my $skip_list = {
		'ajs/perl6-log' => 1,
	};
	my $mods_info = {};
	foreach my $mi ( @$mod_base_info ) {
		my $str_id = $mi->{author} . '/' . $mi->{repo_name};
		if ( $skip_list->{$str_id} ) {
			print "Skipping '$str_id' as module is on skip list.\n" if $self->{vl} >= 4;
			next;
		}
		print "Processing meta file for '$str_id'.\n" if $self->{vl} >= 5;

		my $repo_url = sprintf('git://github.com/%s/%s.git', $mi->{author}, $mi->{repo_name} );
		my $repo_obj = $self->git_repo_obj(
			$mi->{repo_name},
			repo_url => $repo_url,
			skip_fetch => $skip_fetch
		);
		my $meta = $repo_obj->run('show', $mi->{branch}.':'.$mi->{meta_fpath} );
		print "Meta file for '$str_id':\n$meta\n" if $self->{vl} >= 9;

		my $data = eval { $json_obj->decode( $meta ) };
		if ( my $err = $@ ) {
			print "Decoding meta failed: $@\n" if $self->{vl} >= 2;
		}
		$self->dump('meta for '.$str_id, $data ) if $self->{vl} >= 8;

		my $real_repo_url = $data->{'source-url'} // $data->{'repo-url'};
		unless ( $real_repo_url ) {
			croak "'source-url' nor 'repo-url' found for '$str_id'.\n";
			next;
		}

		my $real_repo_name;
		unless ( ($real_repo_name) = $real_repo_url =~ m{([^/]+)\.git$}x ) {
			croak "Can't parse source url '$real_repo_url'\n";
			next;
		}

		if ( exists $mods_info->{$real_repo_name} ) {
			croak "Duplicate repo name '$real_repo_name' found for '$str_id'.\n";
			next;
		}
		$mods_info->{$real_repo_name} = {
			name => $data->{name},
			description => $data->{description},
			'source-url' => $real_repo_url,
			type => [ 'p6-module' ],
		};
	}
	$self->dump('modules info', $mods_info ) if $self->{vl} >= 8;

	foreach my $repo_name ( keys %$mods_info ) {
		if ( exists $self->{pr_info}{$repo_name} ) {
			croak "Duplicate repo name 'repo_name'.\n";
			next;
		}
		$self->{pr_info}{$repo_name} = $mods_info->{$repo_name};
	}
}

sub save_final {
	my ( $self ) = @_;

	my $final_pr_info = $self->projects_final_fpath;
	print "Saving final projects info to '$final_pr_info'.\n" if $self->{vl} >= 3;
	JSON::InFile->new(fpath => $final_pr_info, verbose_level => $self->{vl})->save( $self->{pr_info} );
	return 1;
}

sub run {
	my ( $self, %args ) = @_;
	$args{do_update} //= 1;

	$self->{pr_info} = $self->load_base_list();
	$self->add_p6_modules();

	if ( $args{do_update} ) {
		$self->save_final();
	}
}

1;