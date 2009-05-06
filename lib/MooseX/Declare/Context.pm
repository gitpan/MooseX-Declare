package MooseX::Declare::Context;

use Moose;
use Moose::Util::TypeConstraints;
use Carp qw/croak/;

use aliased 'Devel::Declare::Context::Simple', 'DDContext';

use namespace::clean -except => 'meta';

subtype 'MooseX::Declare::BlockCodePart',
    as 'ArrayRef',
    where { @$_ > 1 and sub { grep { $_[0] eq $_ } qw( BEGIN END ) } -> ($_->[0]) };

subtype 'MooseX::Declare::CodePart',
     as 'Str|MooseX::Declare::BlockCodePart';

has _dd_context => (
    is          => 'ro',
    isa         => DDContext,
    required    => 1,
    builder     => '_build_dd_context',
    lazy        => 1,
    handles     => qr/.*/,
);

has _dd_init_args => (
    is          => 'rw',
    isa         => 'HashRef',
    default     => sub { {} },
    required    => 1,
);

has caller_file => (
    is          => 'rw',
    isa         => 'Str',
    required    => 1,
);

has preamble_code_parts => (
    is          => 'rw',
    isa         => 'ArrayRef[MooseX::Declare::CodePart]',
    required    => 1,
    default     => sub { [] },
);

has scope_code_parts => (
    is          => 'rw',
    isa         => 'ArrayRef[MooseX::Declare::CodePart]',
    required    => 1,
    default     => sub { [] },
);

has cleanup_code_parts => (
    is          => 'rw',
    isa         => 'ArrayRef[MooseX::Declare::CodePart]',
    required    => 1,
    default     => sub { [] },
);

has stack => (
    is          => 'rw',
    isa         => 'ArrayRef',
    default     => sub { [] },
    required    => 1,
);

sub add_preamble_code_parts {
    my ($self, @parts) = @_;
    push @{ $self->preamble_code_parts }, @parts;
}

sub add_scope_code_parts {
    my ($self, @parts) = @_;
    push @{ $self->scope_code_parts }, @parts;
}

sub add_cleanup_code_parts {
    my ($self, @parts) = @_;
    push @{ $self->cleanup_code_parts }, @parts;
}

sub inject_code_parts_here {
    my ($self, @parts) = @_;

    # get code to inject and rest of line
    my $inject  = $self->_joined_statements(\@parts);
    my $linestr = $self->get_linestr;

    # add code to inject to current line and inject it
    substr($linestr, $self->offset, 0, "$inject");
    $self->set_linestr($linestr);

    return 1;
}

sub peek_next_char {
    my ($self) = @_;

    # return next char in line
    my $linestr = $self->get_linestr;
    return substr $linestr, $self->offset, 1;
}

sub peek_next_word {
    my ($self) = @_;

    $self->skipspace;

    my $len = Devel::Declare::toke_scan_word($self->offset, 1);
    return unless $len;

    my $linestr = $self->get_linestr;
    return substr($linestr, $self->offset, $len);
}

sub inject_code_parts {
    my ($self, %args) = @_;

    # default to injecting cleanup code
    $args{inject_cleanup_code_parts} = 1
        unless exists $args{inject_cleanup_code_parts};

    # add preamble and scope statements to injected code
    my $inject;
    $inject .= $self->_joined_statements('preamble');
    $inject .= ';' . $self->_joined_statements('scope');

    # if we should also inject the cleanup code
    if ($args{inject_cleanup_code_parts}) {
        $inject .= ';' . $self->scope_injector_call($self->_joined_statements('cleanup'));
    }

    $inject .= ';';

    # we have a block
    if ($self->peek_next_char eq '{') {
        $self->inject_if_block("$inject");
    }

    # there was no block to inject into
    else {
        # require end of statement
        croak "block or semi-colon expected after " . $self->declarator . " statement"
            unless $self->peek_next_char eq ';';

        # if we can't handle non-blocks, we expect one
        croak "block expected after " . $self->declarator . " statement"
            unless exists $args{missing_block_handler};

        # delegate the processing of the missing block
        $args{missing_block_handler}->($self, $inject, %args);
    }

    return 1;
}

sub _joined_statements {
    my ($self, $section) = @_;

    # if the section was not an array reference, get the
    # section contents of that name
    $section = $self->${\"${section}_code_parts"}
        unless ref $section;

    # join statements via semicolon
    # array references are expected to be in the form [FOO => 1, 2, 3]
    # which would yield BEGIN { 1; 2; 3 }
    return join '; ', map {
        not( ref $_ ) ? $_ : do {
            my ($block, @parts) = @$_;
            sprintf '%s { %s }', $block, join '; ', @parts;
        };
    } @{ $section };
}

sub BUILD {
    my ($self, $attrs) = @_;

    # remember the constructor arguments for the delegated context
    $self->_dd_init_args($attrs);
}

sub _build_dd_context {
    my ($self) = @_;

    # create delegated context with remembered arguments
    return DDContext->new(%{ $self->_dd_init_args });
}

sub strip_word {
    my ($self) = @_;

    $self->skipspace;
    my $linestr = $self->get_linestr;
    return if substr($linestr, $self->offset, 1) =~ /[{;]/;

    # TODO:
    # - provide a reserved_words attribute
    # - allow keywords to consume reserved_words autodiscovery role
    my $word = $self->peek_next_word;
    return if !defined $word || $word =~ /^(?:extends|with|is)$/;

    return scalar $self->strip_name;
}

1;

__END__

=head1 NAME

MooseX::Declare::Context - Per-keyword declaration context

=head1 DESCRIPTION

This is not a subclass of L<Devel::Declare::Context::Simple>, but it will
delegate all default methods and extend it with some attributes and methods
of its own.

A context object will be instanciated for every keyword that is handled by
L<MooseX::Declare>. If handlers want to communicate with other handlers (for
example handlers that will only be setup inside a namespace block) it must
do this via the generated code.

=head1 TYPES

=head2 CodePart

A part of code represented by either a C<Str> or a L</BlockCodePart>.

=head2 BlockCodePart

An C<ArrayRef> with at least one element that stringifies to either C<BEGIN>
or C<END>. The other parts will be stringified and used as the body for the
generated block. An example would be this compiletime role composition:

  ['BEGIN', 'with q{ MyRole }']

=head1 ATTRIBUTES

=head2 caller_file

A required C<Str> containing the file the keyword was encountered in.

=head2 preamble_code_parts

An C<ArrayRef> of L</CodePart>s that will be used as preamble. A preamble in
this context means the beginning of the generated code.

=head2 scope_code_parts

These parts will come before the actual body and after the
L</preamble_code_parts>. It is an C<ArrayRef> of L</CodePart>s.

=head2 cleanup_code_parts

An C<ArrayRef> of L</CodePart>s that will not be directly inserted
into the code, but instead be installed in a handler that will run at
the end of the scope so you can do namespace cleanups and such.

=head2 stack

An C<ArrayRef> that contains the stack of handlers. A keyword that was
only setup inside a scoped block will have the blockhandler be put in
the stack.

=head1 METHODS

All methods from L<Devel::Declare::Context::Simple> should be available and
will be delegated to an internally stored instance of it.

=head2 add_preamble_code_parts(CodePart @parts)

=head2 add_scope_code_parts(CodePart @parts)

=head2 add_cleanup_code_parts(CodePart @parts)

  Object->add_preamble_code_parts (CodeRef @parts)
  Object->add_scope_code_parts    (CodeRef @parts)
  Object->add_cleanup_code_parts  (CodeRef @parts)

For these three methods please look at the corresponding C<*_code_parts>
attribute in the list above. These methods are merely convenience methods
that allow adding entries to the code part containers.

=head2 inject_code_parts_here

  True Object->inject_code_parts_here (CodePart @parts)

Will inject the passed L</CodePart>s at the current position in the code.

=head2 peek_next_char

  Str Object->peek_next_char ()

Will return the next char without stripping it from the stream.

=head2 inject_code_parts

  Object->inject_code_parts (
      Bool    :$inject_cleanup_code_parts,
      CodeRef :$missing_block_handler
  )

This will inject the code parts from the attributes above at the current
position. The preamble and scope code parts will be inserted first. Then
then call to the cleanup code will be injected, unless the options
contain a key named C<inject_cleanup_code_parts> with a false value.

The C<inject_if_block> method will be called if the next char is a C<{>
indicating a following block.

If it is not a block, but a semi-colon is found and the options
contained a C<missing_block_handler> key was passed, it will be called
as method on the context object with the code to inject and the
options as arguments. All options that are not recognized are passed
through to the C<missing_block_handler>. You are well advised to prefix
option names in your extensions.

=head2 strip_name_and_options

  List Object->strip_name_and_options ()

This will remove an identifier plus any options that follow it from the
stream. Options are things like C<is Trait>, C<with Role> and
C<extends ParentClass>. Currently, only these are supported.

The return value is a list with two values:

=over

=item Str $name

The name that was read.

=item HashRef $options

The options that followed the name. This is the returned format:

  Dict[
      is      => HashRef[Bool],
      extends => ArrayRef[ParentClass],
      with    => ArrayRef[Role],
  ]

=back

=head1 SEE ALSO

=over

=item * L<MooseX::Declare>

=item * L<Devel::Declare>

=item * L<Devel::Declare::Context::Simple>

=back

=head1 AUTHOR, COPYRIGHT & LICENSE

See L<MooseX::Declare>

=cut
