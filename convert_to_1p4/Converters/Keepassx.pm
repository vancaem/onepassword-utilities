# KeePassX XML export converter
#
# Copyright 2014 Mike Cappella (mike@cappella.us)

package Converters::Keepassx 1.00;

our @ISA 	= qw(Exporter);
our @EXPORT     = qw(do_init do_import do_export);
our @EXPORT_OK  = qw();

use v5.14;
use utf8;
use strict;
use warnings;
#use diagnostics;

binmode STDOUT, ":utf8";
binmode STDERR, ":utf8";

use Utils::PIF;
use Utils::Utils qw(verbose debug bail pluralize myjoin print_record);
use XML::XPath;
use XML::XPath::XMLParser;

my %card_field_specs = (
    login =>			{ textname => undef, fields => [
	[ 'url',		1, qr/^url$/, ],
	[ 'username',		1, qr/^username$/, ],
	[ 'password',		1, qr/^password$/, ],
    ]},
    note =>                     { textname => undef, fields => [
    ]},
);

$DB::single = 1;					# triggers breakpoint when debugging

sub do_init {
    return {
	'specs'		=> \%card_field_specs,
	'imptypes'  	=> undef,
	'opts'		=> [],
    };
}

sub do_import {
    my ($file, $imptypes) = @_;

    {
	local $/ = undef;
	open my $fh, '<', $file or bail "Unable to open file: $file\n$!";
	$_ = <$fh>;
	s!<br/>!\n!g;
	close $fh;
    }

    my %Cards;
    my $n = 1;
    my ($npre_explode, $npost_explode);

    my $xp = XML::XPath->new(xml => $_);
    my $groupnodes = $xp->find('//group');
    foreach my $groupnode ($groupnodes->get_nodelist) {
	my (@groups, $card_tags);
	for (my $node = $groupnode; my $parent = $node->getParentNode(); $node = $parent) {
	    my $v = $xp->findvalue('title', $node)->value();
	    unshift @groups, $v   unless $v eq '';
	}
	$card_tags = join '::', @groups;
	debug 'Group: ', $card_tags;
	my $entrynodes = $xp->find('entry', $groupnode);
	foreach my $entrynode ($entrynodes->get_nodelist) {
	    debug "\tEntry:";
	    my @fields;

	    my $card_title = $xp->findvalue('title',   $entrynode)->value();
	    my $card_note  = $xp->findvalue('comment', $entrynode)->value();

	    for (qw/username password url lastaccess lastmod creation expire/) {
		my $val = $xp->findvalue($_, $entrynode)->value();
		next if $val eq '';
		push @fields, [ $_ => $val ];		# retain field order
		debug "\t\t$_: ", $val;
	    }

	    my $itype = find_card_type(\@fields);

	    # skip all types not specifically included in a supplied import types list
	    next if defined $imptypes and (! exists $imptypes->{$itype});

	    # From the card input, place it in the converter-normal format.
	    # The card input will have matched fields removed, leaving only unmatched input to be processed later.
	    my $normalized = normalize_card_data($itype, \@fields, $card_title, $card_tags, \$card_note, \@groups);

	    # Returns list of 1 or more card/type hashes;possible one input card explodes to multiple output cards
	    # common function used by all converters?
	    my $cardlist = explode_normalized($itype, $normalized);

	    my @k = keys %$cardlist;
	    if (@k > 1) {
		$npre_explode++; $npost_explode += @k;
		debug "\tcard type $itype expanded into ", scalar @k, " cards of type @k"
	    }
	    for (@k) {
		print_record($cardlist->{$_});
		push @{$Cards{$_}}, $cardlist->{$_};
	    }
	    $n++;
	}
    }

    $n--;
    verbose "Imported $n card", pluralize($n) ,
	$npre_explode ? " ($npre_explode card" . pluralize($npre_explode) .  " expanded to $npost_explode cards)" : "";
    return \%Cards;
}

sub do_export {
    create_pif_file(@_);
}

sub find_card_type {
    my $type = grep($_->[0] =~ /^url|username|password$/, @{$_[0]}) ? 'login' : 'note';
    debug "type detected as '$type'";
    return $type;
}

# Place card data into normalized internal form.
# per-field normalized hash {
#    inkey	=> imported field name
#    value	=> field value after callback processing
#    valueorig	=> original field value
#    outkey	=> exported field name
#    outtype	=> field's output type (may be different than card's output type)
#    keep	=> keep inkey:valueorig pair can be placed in notes
#    to_title	=> append title with a value from the narmalized card
# }
sub normalize_card_data {
    my ($type, $fieldlist, $title, $tags, $notesref, $folder, $postprocess) = @_;
    my %norm_cards = (
	title	=> $title,
	notes	=> defined $$notesref ? $$notesref : '',
	tags	=> $tags,
	folder	=> $folder,
    );

    for my $def (@{$card_field_specs{$type}{'fields'}}) {
	my $h = {};
	for (my $i = 0; $i < @$fieldlist; $i++) {
	    my ($inkey, $value) = @{$fieldlist->[$i]};
	    next if not defined $value or $value eq '';

	    if ($inkey =~ $def->[2]) {
		my $origvalue = $value;

		if (exists $def->[3] and exists $def->[3]{'func'}) {
		    #         callback(value, outkey)
		    my $ret = ($def->[3]{'func'})->($value, $def->[0]);
		    $value = $ret	if defined $ret;
		}
		$h->{'inkey'}		= $inkey;
		$h->{'value'}		= $value;
		$h->{'valueorig'}	= $origvalue;
		$h->{'outkey'}		= $def->[0];
		$h->{'outtype'}		= $def->[3]{'type_out'} || $card_field_specs{$type}{'type_out'} || $type; 
		$h->{'keep'}		= $def->[3]{'keep'} // 0;
		$h->{'to_title'}	= ' - ' . $h->{$def->[3]{'to_title'}}	if $def->[3]{'to_title'};
		push @{$norm_cards{'fields'}}, $h;
		splice @$fieldlist, $i, 1;	# delete matched so undetected are pushed to notes below
	    }
	}
    }

    # map remaining keys to notes
    $norm_cards{'notes'} .= "\n"	if defined $norm_cards{'notes'} and length $norm_cards{'notes'} > 0 and @$fieldlist;
    for (@$fieldlist) {
	next if $_->[1] eq '';
	$norm_cards{'notes'} .= "\n"	if defined $norm_cards{'notes'} and length $norm_cards{'notes'} > 0;
	$norm_cards{'notes'} .= join ': ', @$_;
    }

    return \%norm_cards;
}

1;
