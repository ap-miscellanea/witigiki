#!/usr/bin/perl
use 5.010;
use strict;
use warnings;
no warnings qw( once qw );

package WitiGiki::Context;

use Plack::Request ();
use XML::Builder ();
use Try::Tiny ();
use File::MimeInfo::Magic ();
use Text::Markdown ();
use Encode ();

use Object::Tiny qw( req res );

sub new {
	my $class = shift;
	my $self = bless { @_ }, $class;
	$self->{'res'} //= $self->req->new_response;
	return $self;
}

sub git {
	my $self = shift;
	open my $rh, '-|', git => @_ or die $!;
	local $/;
	binmode $rh;
	return scalar <$rh>;
}

sub get_type {
	my $self = shift;
	my $_ = $self->git( 'cat-file' => -t => "HEAD:$_[0]" );
	s!\s+\z!!;
	return $_;
}

sub get_file { shift->git( 'cat-file' => blob => "HEAD:$_[0]" ) }

sub get_mimetype {
	my $self = shift;
	my ( $filename, $fh ) = @_;
	my $type = File::MimeInfo::Magic::mimetype $fh;
	$type = ( File::MimeInfo::Magic::globs $filename ) // $type
		if $type eq 'application/octet-stream'
		or $type eq 'text/plain';
	return $type;
}

sub dir_style { "\n".<<'' }
ul, li { margin: 0; padding: 0 }
li { list-style-type: none }

sub render_listing {
	my $self = shift;
	my $path = shift;

	my $x = XML::Builder->new;
	my $h = $x->register_ns( 'http://www.w3.org/1999/xhtml', '' );

	return $x->root( $h->html(
		$h->head(
			$h->title( $path ),
			$h->style( { type => 'text/css' }, $self->dir_style )
		),
		$h->body( $h->ul( "\n", map {; $_, "\n" } $h->li->foreach(
			map {
				my $class = m!(\A\.\.|/)\z! ? 'd' : 'f';
				$h->a( { href => $_, class => $class }, $_ );
			} @_
		) ) ),
	) );
}

sub serve_404 {
	my $self = shift;

	my $x = XML::Builder->new;
	my $h = $x->register_ns( 'http://www.w3.org/1999/xhtml', '' );

	my $res = $self->res;
	$res->status( 404 );
	$res->content_type( 'application/xhtml+xml' );
	$res->body( $x->root( $h->html(
		$h->head( $h->title( $self->req->uri->as_string ) ),
		$h->body( $h->h1( '404 Not Found' ) ),
	) ) );
}

sub serve_500 {
	my $self = shift;
	my ( $error ) = @_;

	my $x = XML::Builder->new;
	my $h = $x->register_ns( 'http://www.w3.org/1999/xhtml', '' );

	my $res = $self->res;
	$res->status( 500 );
	$res->content_type( 'application/xhtml+xml' );
	$res->body( $x->root( $h->html(
		$h->head( $h->title( 'Internal Server Error' ) ),
		$h->body( $h->pre( $error ) ),
	) ) );
}

sub serve_dir301 {
	my $self = shift;
	my $res = $self->res;
	my $uri = $self->req->uri->clone;
	$uri->path( $uri->path . '/' );
	$res->redirect( $uri, 301 );
}

sub serve_listing {
	my $self = shift;
	my ( $path ) = @_;

	$path =~ s!/*\z!/!;

	my $prefix;
	$prefix = qr(\A\Q$path) if $path ne '/';

	my @entry
		= sort {
			( ( $b =~ m!/\z! ) <=> ( $a =~ m!/\z! ) )  # dirs first
			|| ( lc $a cmp lc $b )
		}
		map {
			my ( $mode, $type, $sha1, $name ) = /\A (\S+) [ ] (\S+) [ ] (\S+) \t (.*) \z/sx;
			$name =~ s!$prefix!! if $prefix;
			$name .= '/' if $type eq 'tree';
			$name =~ s!\.mkd\z!!;
			$name;
		}
		split /\0/,
		$self->git( 'ls-tree' => -z => HEAD => ( $prefix ? $path : () ) );

	unshift @entry, '..' if $prefix;

	my $res = $self->res;
	$res->status( 200 );
	$res->content_type( 'application/xhtml+xml' );
	$res->body( $self->render_listing( $path, @entry ) );
}

sub serve_file {
	my $self = shift;
	my ( $path ) = @_;
	my $res = $self->res;
	$res->status( 200 );
	my $body = $self->get_file( $path );
	open my $fh, '<', \$body;

	if ( $path =~ s!\.mkd\z!! ) {
		$res->content_type( 'application/xhtml+xml' );
		Encode::from_to( $body, 'UTF-8', 'us-ascii', Encode::FB_HTMLCREF );
		$body = Text::Markdown::markdown( $body );
		$body = do {
			my $title = $body =~ m{<h1>(.*?)</h1>} ? $1 : $path;
			$title =~ s/<[^<]*>//g;
			<<"";
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>$title</title></head>
<body>
$body
</body>
</html>

		};
	}
	else {
		$res->content_type( $self->get_mimetype( $path, $fh ) );
		seek $fh, 0, 0;
	}

	$res->status( 200 );
	$res->body( $fh );
}

sub serve_path; # to foil the bloody indirect method syntax
sub serve_path {
	my $self = shift;
	my ( $path ) = @_;

	$path //= $self->req->path // '';
	$path =~ s!\A/!!;

	warn "trying $path";

	given ( $self->get_type( $path ) ) {
		when ( 'blob' ) { $self->serve_file( $path ) }
		when ( 'tree' ) {
			$path !~ m!(?:\A|/)\z!
				? $self->serve_dir301
				: $self->serve_path( $path . 'index' )
				  || $self->serve_listing( $path );
		}
		default {
			$path =~ m!(?:\A|/|\.mkd)\z!
				? $self->serve_404
				: $self->serve_path( $path . '.mkd' );
			return;
		}
	}

	return 1;
}

package WitiGiki;

use parent 'Plack::Middleware';
use Object::Tiny qw( app );

use HTML::Tidy ();

sub class { 'WitiGiki::Context' }

sub tidy_options { +{
	show_warnings               => 'no',
	show_errors                 => 0,

	output_xhtml                => 'yes',
	doctype                     => 'strict',
	add_xml_decl                => 'no',

	drop_empty_paras            => 'no',
	drop_proprietary_attributes => 'yes',
	fix_uri                     => 'yes',
	logical_emphasis            => 'no',
	enclose_text                => 'yes',
	enclose_block_text          => 'yes',
	replace_color               => 'yes',
	numeric_entities            => 'yes',

	indent                      => 'no',
	indent_attributes           => 'no',
	indent_spaces               => 4,
	markup                      => 'yes',
	tab_size                    => 4,
	wrap                        => 0,

	newline                     => 'LF',
	output_encoding             => 'utf8',
	ascii_chars                 => 'no',

	fix_backslash               => 'yes',
	tidy_mark                   => 'no',
} }

sub tidy {
	my $self = shift;
	$self->{'tidy'} //= do {
		my $tidy = HTML::Tidy->new( $self->tidy_options );
		$tidy->ignore( type => HTML::Tidy::TIDY_WARNING );
		$tidy->ignore( type => HTML::Tidy::TIDY_ERROR );
		$tidy;
	};
}

sub call {
	my $self = shift;
	my $ctx = $self->class->new( req => Plack::Request->new( shift ), tidy => $self->tidy );
	Try::Tiny::try { $ctx->serve_path } sub { $ctx->serve_500( $_ ) };
	$ctx->res->finalize;
}

1;
