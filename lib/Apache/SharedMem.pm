package Apache::SharedMem;
#$Id: SharedMem.pm,v 1.20 2001/06/26 21:09:46 rs Exp $

=pod

=head1 NAME

Apache::SharedMem - Share data between Apache children prcesses through the shared memory

=head1 SYNOPSIS

    use Apache::SharedMem qw(:lock :wait);

    my $share = new Apache::SharedMem;

    $share->set(key=>'some data');

    # ...in another process
    my $var = $share->get(key, NOWAIT);
    die("can't get key: ", $self->error) unless(defined $var);

    $share->delete(key);

    $share->clear if($share->size > $max_size);

    if($share->lock(LOCK_EX|LOCK_NB))
    {
        my $data...
        ...some traitement...
        $share->set(key=>$data);
        $share->unlock;
    }
    
    $share->release;

=head1 DESCRIPTON

This module make it easier to share data between Apache children processes trough the shared memory.
This module internal working is a lot inspired by IPC::SharedCache, but without any cache managment.
The share memory segment key is automatically deduced by the caller package, that's mine 2 modules
can use same keys without be concerned about namespace clash.

This module handles all shared memory interaction use the IPC::SharedLite module and all data 
serialization using Storable. See L<IPC::ShareLite> and L<Storable> for details.

=head1 USAGE

in construction

=cut

BEGIN
{
    use strict;
    use 5.005;
    use Carp;
    use IPC::ShareLite qw(:lock);
    use Storable qw(freeze thaw);
    use Exporter ();

    @Apache::SharedMem::ISA         = qw(Exporter);
    %Apache::SharedMem::EXPORT_TAGS = 
    (
        'all'   => [qw(
                       LOCK_EX LOCK_SH LOCK_UN LOCK_NB WAIT NOWAIT
                       WAIT NOWAIT
                       SUCCESS FAILURE
                   )],
        'lock'  => [qw(LOCK_EX LOCK_SH LOCK_UN LOCK_NB WAIT NOWAIT)], 
        'wait'  => [qw(WAIT NOWAIT)],
        'status'=> [qw(SUCCESS FAILURE)],
    );
    @Apache::SharedMem::EXPORT_OK   = @{$Apache::SharedMem::EXPORT_TAGS{'all'}};

    use constant WAIT       => 1;
    use constant NOWAIT     => 0;
    use constant SUCCESS    => 1;
    use constant FAILURE    => 0;

    $Apache::SharedMem::VERSION = '0.03';
}

=pod

=head1 METHODS

=head2 new  (namespace => 'Namespace', ipc_mode => 0666, ipc_segment_size => 1_000, debug => 1)

rootname (optional): change the default root name segment identifier (default: TOOR).

namespace (optional): setup manually the package name (default: caller package name).

ipc_mode (optional): setup manually segment mode (see IPC::ShareLite man page) (default: 0666).

ipc_segment_size (optional): setup manually segment size (see IPC::ShareLite man page) (default: 65_536).

debug (optional): turn on/off debug mode (default: 0)

In most case, you don't need to give any arguments to the constructor. But for some resons, (like share
the same namespace between 2 modules) you can setup some parameters manually.

Note that ipc_segment_size is 

=cut

sub new 
{
    my $pkg = shift;
    my $self = bless({}, ref($pkg) || $pkg);

    my $options = $self->{options} =
    {
        rootname            => 'TOOR', # TODO find another solution for a more unique rootspace
        namespace           => (caller())[0],
        ipc_mode            => undef(), # not really managed for moment
        ipc_segment_size    => 65_536,
        debug               => 0,
    };

    croak("odd number of arguments for object construction")
      if(@_ % 2);
    for(my $x = 0; $x <= $#_; $x += 2)
    {
        croak("Unknown parameter $_[$x] in $pkg object creation")
          unless(exists($options->{lc($_[$x])}));
        $options->{lc($_[$x])} = $_[($x + 1)];
    }

    foreach my $name (qw(namespace))
    {
        croak("$pkg object creation missing $name parameter.")
          unless(defined($options->{$name}) && $options->{$name} ne '');
    }

    $self->_debug("create Apache::SharedMem instence. options: ", join(', ', map("$_ => " . (defined($options->{$_}) ? $options->{$_} : 'UNDEF'), keys %$options)))
      if($options->{debug});

    require('Data/Dumper.pm') if($options->{debug});

    $self->_init_namespace;

    return $self;
}

=pod

=head2 get  (key, wait)

my $var = $object->get('mykey');
if($object->status eq FAILURE)
{
    die("can't get key 'mykey´: " . $object->error);
}

key (required): key to get from shared memory

wait (optional): WAIT or NOWAIT (default WAIT) make or not a blocking shared lock (need :wait tag import).

Try to get element C<key> from the shared segment. On failure, this methode return C<undef()> and set status to FAILURE.

status: SUCCESS FAILURE

=cut

sub get
{
    my $self    = shift || croak('invalide method call');
    my $key     = defined($_[0]) && $_[0] ne '' ? shift : croak(defined($_[0]) ? 'Not enough arguments for get method' : 'Invalid argument "" for get method');
    my $wait    = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for get method') if(@_);
    $self->_unset_error;
    
    $self->_debug("$key ", $wait ? '(wait)' : '(no wait)');

    my($lock_success, $out_lock) = $self->_smart_lock($wait ? LOCK_SH : LOCK_SH|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get shared lock for "get" method');
        $self->_set_status(FAILURE);
        return(undef());
    }

    # extract datas from the shared memory
    my $share = $self->_get_namespace;

    $self->lock($out_lock);

    if(exists $share->{$key})
    {
        $self->_set_status(SUCCESS);
        return(defined($share->{$key}) ? $share->{$key} : '');
    }
    else
    {
        $self->_set_status(FAILURE);
        $self->_set_error("can't get key $key, it doesn't exists");
        return(undef());
    }
}

=pod

=head2 set  (key, value, wait)

my $rv = $object->set('mykey' => 'somevalue');
if($object->status eq FAILURE)
{
    die("can't set key 'mykey´: " . $object->error);
}

key (required): key to set

value (required): value a store in key

wait (optional): WAIT or NOWAIT (default WAIT) make or not a blocking shared lock (need :wait tag import).

Try to set element C<key> to C<value> from the shared segment. On failure, this methode return C<undef()>.

status: SUCCESS FAILURE

=cut

sub set
{
    my $self    = shift || croak('invalid method call');
    my $key     = defined($_[0]) && $_[0] ne '' ? shift : croak(defined($_[0]) ? 'Not enough arguments for set method' : 'Invalid argument "" for set method');
    my $value   = defined($_[0]) ? shift : croak('Not enough arguments for set method');
    my $wait    = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for set method') if(@_);
    $self->_unset_error;
    
    $self->_debug("$key $value ", $wait ? '(wait)' : '(no wait)');

    my($lock_success, $out_lock) = $self->_smart_lock($wait ? LOCK_EX : LOCK_EX|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get exclusive lock for "set" method');
        $self->_set_status(FAILURE);
        return(undef());
    }

    my $share = $self->_get_namespace;
    $share->{$key} = $value;
    $self->_store_namespace($share);

    $self->lock($out_lock);

    $self->_set_status(SUCCESS);
    # return value, like a common assigment
    return($value);
}

=pod

=head2 delete  (key, wait)

=cut

sub delete
{
    my $self = shift;
    my $key  = defined($_[0]) ? shift : croak('Not enough arguments for delete method');
    my $wait = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for delete method');
    $self->_unset_error;

    $self->_debug("$key ", $wait ? '(wait)' : '(no wait)');

    my $exists = $self->exists($key, $wait);
    if(!defined $exists)
    {
        $self->_set_error("can\'t delete key '$key': ", $self->error);
        $self->_set_status(FAILURE);
        return(undef());
    }
    elsif(!$exists)
    {
        $self->_debug("DELETE[$$]: key '$key' wasn't exists");
        $self->_set_status(FAILURE);
        return(undef());
    }

    my($lock_success, $out_lock) = $self->_smart_lock($wait ? LOCK_EX : LOCK_EX|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get exclusive lock for "delete" method');
        $self->_set_status(FAILURE);
        return(undef());
    }


    my $share = $self->_get_namespace;
    my $rv    = delete($share->{$key});
    $self->_store_namespace($share);
   
    $self->lock($out_lock);

    $self->set_status(SUCCESS);
    # like a real delete
    return($rv);
}

=pod

=head2 exists  (key, wait)

=cut

sub exists
{
    my $self = shift;
    my $key  = defined($_[0]) ? shift : croak('Not enough arguments for exists method');
    my $wait = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for exists method') if(@_);
    $self->_unset_error;

    $self->_debug("key: $key");

    my($lock_success, $out_lock) = $self->_smart_lock($wait ? LOCK_SH : LOCK_SH|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get shared lock for "exists" method');
        $self->_set_status(FAILURE);
        return(undef());
    }

    my $share = $self->_get_namespace;

    $self->lock($out_lock);

    $self->_set_status(SUCCESS);
    return(exists $share->{$key});
}

=pod

=head2 firstkey  (wait)

=cut

sub firstkey
{
    my $self = shift;
    my $wait = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for firstkey method') if(@_);
    $self->_unset_error;

    my($lock_success, $out_lock) = $wait ? $self->_smart_lock(LOCK_SH) : $self->_smart_lock(LOCK_SH|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get shared lock for "firstkey" method');
        $self->_set_status(FAILURE);
        return(undef());
    }

    my $share = $self->_get_namespace;

    $self->lock($out_lock);
    
    my $firstkey = (keys(%$share))[0];
    $self->_set_status(SUCCESS);
    return($firstkey, $share->{$firstkey});
}

=pod

=head2 nextkey  (lastkey, wait)

=cut

sub nextkey
{
    my $self    = shift;
    my $lastkey = defined($_[0]) ? shift : croak('Not enough arguments for nextkey method');
    my $wait    = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for nextkey method') if(@_);
    $self->_unset_error;

    my($lock_success, $out_lock) = $self->_smart_lock($wait ? LOCK_SH : LOCK_SH|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get shared lock for "nextkey" method');
        $self->_set_status(FAILURE);
        return(undef());
    }

    my $share = $self->_get_namespace;

    $self->lock($out_lock);
    
    $self->_set_status(SUCCESS);
    my @keys = keys %share;
    for(my $x = 0; $x < $#keys; $x++)
    {
        return($share->{$keys[$x+1]}) if($share->{$keys[$x]} eq $lastkey);
    }
    return(undef());
}

=pod

=head2 clear

return 0 on error

=cut

sub clear
{
    my $self    = shift;
    my $wait    = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for clear method') if(@_);
    $self->_unset_error;

    my($lock_success, $out_lock) = $self->_smart_lock($wait ? LOCK_EX : LOCK_EX|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get shared lock for "clear" method');
        $self->_set_status(FAILURE);
        return(0);
    }

    $self->_store_namespace({});

    $self->lock($out_lock);
    
    $self->_set_status(SUCCESS);
    return(undef());
}

sub release
{
    my $self    = shift;
    my $options = $self->{options};
    $self->_unset_error;

    $self->_root_lock(LOCK_EX);
    my $root  = $self->_get_root;
    my $keyid = delete($root->{'map'}->{$options->{namespace}});
    $self->_store_root($root);
    $self->_root_unlock;

    delete($self->{namespace});

    my $share = new IPC::ShareLite
    (
        -key        => $keyid,
        -size       => $options->{ipc_segment_size},
        -create     => 0,
        -destroy    => 1,
    );
    unless(defined $share)
    {
        $self->_set_error("Apache::SharedMem: unable to get shared cache block: $!");
        $self->_set_status(FAILURE);
        return(undef());
    }

    $self->_set_status(SUCCESS);
    return(1);
}

=pod

=head2 size (wait)

=cut

sub size
{
    my $self = shift;
    my $wait = defined($_[0]) ? shift : (shift, 1);
    croak('Too many arguments for size method') if(@_);
    $self->_unset_error;

    my($lock_success, $out_lock) = $self->_smart_lock($wait ? LOCK_SH : LOCK_SH|LOCK_NB);
    unless($lock_success)
    {
        $self->_set_error('can\'t get shared lock for "size" method');
        $self->_set_status(FAILURE);
        return(undef());
    }

    my $serialized;
    eval { $serialized = $self->{namespace}->fetch(); };
    confess("Apache::SharedMem: Problem fetching segment. IPC::ShareLite error: $@") if $@;
    confess("Apache::SharedMem: Problem fetching segment. IPC::ShareLite error: $!") unless(defined $serialized);

    $self->lock($out_lock);

    $self->_set_status(SUCCESS);
    return(length $serialized);
}

=pod

=head2 lock ($lock_type)

lock_type (optional): type of lock (LOCK_EX, LOCK_SH, LOCK_NB, LOCK_UN)

get a lock on the root share segment. return 0 of undef on failure, 1 on success.

=cut

sub lock
{
    my($self, $type) = @_;
    $self->_debug("type $type"); 
    my $rv = $self->_lock($type, $self->{namespace});
    $self->{_lock_status} = $type if($rv);
    return($rv);
}

sub _root_lock  { $_[0]->_debug("type $_[1]"); $_[0]->_lock($_[1], $_[0]->{root}) }

sub _lock
{
    confess('Apache::SharedMem: Not enough arguments for lock method') if(@_ < 3);
    my($self, $type, $ipc_obj) = @_;
    $self->_unset_error;

    return($self->unlock) if($type eq LOCK_UN); # strang bug, LOCK_UN, seem not to be same as unlock for IPC::ShareLite... 

    # get a lock
    $ipc_obj->lock($type) or
    do 
    {
        $self->_set_error("Can\'t lock share $self->{options}->{namespace} segment");
        $self->_set_status(FAILURE);
        return(undef());
    };
    $self->_set_status(SUCCESS);
    return(1);
}

=pod

=head2 unlock

freeing a lock

=cut

sub unlock
{
    my $self = shift;
    $self->_debug;
    my $rv = $self->_unlock($self->{namespace});
    $self->{_lock_status} = LOCK_UN if($rv);
    return($rv);
}
sub _root_unlock { $_[0]->_debug; $_[0]->_unlock($_[0]->{root}) }

sub _unlock
{
    my($self, $ipc_obj) = @_;
    $self->_unset_error;

    $ipc_obj->unlock or
    do
    { 
        $self->_set_error("Can't unlock segment"); 
        $self->_set_status(FAILURE);
        return(undef());
    };
    $self->_set_status(SUCCESS);
    return(1);
}

=pod

=head2 error

return the last happened error message.

=cut

sub error  { return($_[0]->{__last_error__}); }

sub status { return($_[0]->{__status__}); }

sub _smart_lock
{
    # this method try to implement a smart fashion to manage locks.
    # problem is when user place manually a lock before a get, set,... call. the
    # methode handle his own lock, and in this code :
    #   $share->lock(LOCK_EX);
    #   my $var = $share->get(key);
    #   ...make traitement on $var
    #   $share->set(key=>$var);
    #   $share->unlock;
    #
    # in this example, the first "get" call, change the lock for a share lock, and free
    # the lock at the return.
    # 
    my($self, $type) = @_;
    
    if(!defined($self->{_lock_status}) || $self->{_lock_status} eq LOCK_UN)
    {
        # no lock have been set, act like a normal lock
        $self->_debug("locking type $type, return LOCK_UN");
        return($self->lock($type), LOCK_UN);
    }
    elsif(($self->{_lock_status} eq LOCK_SH || $self->{_lock_status} eq (LOCK_SH|LOCK_NB))
      && ($type eq LOCK_EX || $type eq (LOCK_EX|LOCK_NB)))
    {
        # the current lock is less powerfull than targeted lock type
        $self->_debug("locking type $type, return $self->{_lock_status}");
        return($self->lock($type), $self->{_lock_status});
    }

    $self->_debug("live lock untouch, return $self->{_lock_status}");
    return(1, $self->{_lock_status});
}

sub _init_root
{
    my $self    = shift;
    my $options = $self->{options};
    my $record;

    # try to get a handle on an existing root for this namespace
    my $root = new IPC::ShareLite
    (
        -key        => $options->{rootname},
        -mode       => $options->{ipc_mode},
        -size       => $options->{ipc_segment_size},
        -create     => 0,
        -destroy    => 0,
    );

    if(defined $root)
    {
        # we have found an existing root
        $self->{root} = $root;
        $self->_root_lock(LOCK_SH);
        $record = $self->_get_root;
        $self->_root_unlock;
        return($record);
    }

    $self->_debug('ROOT INIT');

    # prepare empty root record for new root creation
    $record = 
    {
        'map'       => {},
        'last_key'  => 1,
    };

    $root = new IPC::ShareLite
    (
        -key        => $options->{rootname},
        -mode       => $options->{ipc_mode},
        -size       => $options->{ipc_segment_size},
        -create     => 1,
        -exclusive  => 1,
        -destroy    => 0,
    );
    confess("Apache::SharedMem object initialization: Unable to initialize root ipc shared memory segment: $!")
      unless(defined $root);

    $self->{root} = $root;
    $self->_root_lock(LOCK_EX);
    $self->_store_root($record);
    $self->_root_unlock;

    return($record);
}

sub _init_namespace
{
    my $self        = shift;
    my $options     = $self->{options};
    my $namespace   = $options->{namespace};

    my $rootrecord  = $self->_init_root;

    my $share;
    if(exists $rootrecord->{'map'}->{$namespace})
    {
        $self->_debug('namespace exists');
        # namespace already exists
        $share = new IPC::ShareLite
        (
            -key            => $rootrecord->{'map'}->{$namespace},
            -mode           => $options->{ipc_mode},
            -size           => $options->{ipc_segment_size},
            -create         => 0,
            -destroy        => 0,
        );
        confess("Apache::SharedMem: Unable to get shared cache block $self->{root}->{'map'}->{$key}: $!") unless(defined $share);
    }
    else
    {
        $self->_debug('namespace doesn\'t exists, creating...');
        # otherwise we need to find a new segment
        my $ipc_key = $rootrecord->{'last_key'};
        for(my $end = $ipc_key + 10_000; $ipc_key != $end; $ipc_key++)
        {
            $share = new IPC::ShareLite
            (
                -key        => $ipc_key,
                -mode       => $options->{ipc_mode},
                -size       => $options->{ipc_segment_size},
                -create     => 1,
                -exclusive  => 1,
                -destroy    => 0,
            );
            last if(defined $share);
        }
        croak("Apache::SharedMem: searched through 10,000 consecutive locations for a free shared memory segment, giving up: $!")
          unless(defined $share);

        # update the root record
        $self->_root_lock(LOCK_EX);
        $rootrecord->{'last_key'}           = $ipc_key;
        $rootrecord->{'map'}->{$namespace}  = $ipc_key;
        $self->_store_root($rootrecord);
        $self->_root_unlock;
    }

    return($self->{namespace} = $share);
}

sub _get_namespace { $_[0]->_debug; $_[0]->_get_record($_[0]->{namespace}) }
sub _get_root      { $_[0]->_debug; $_[0]->_get_record($_[0]->{root}) }

sub _get_record
{
    my($self, $ipc_obj) = @_;

    my($serialized, $record);

    # fetch the shared block
    eval { $serialized = $ipc_obj->fetch(); };
    confess("Apache::SharedMem: Problem fetching segment. IPC::ShareLite error: $@") if $@;
    confess("Apache::SharedMem: Problem fetching segment. IPC::ShareLite error: $!") unless(defined $serialized);

    $self->_debug(4, 'storable src: ', $serialized);

    if($serialized ne '')
    {
        # thaw the shared block
        eval { $record = thaw($serialized) };
        confess("Apache::SharedMem: Invalid share block recieved from shared memory. Storable error: $@") if $@;
        confess("Apache::SharedMem: Invalid share block recieved from shared memory.") unless(ref($record) eq 'HASH');
    }
    else
    {
        # record not initialized
        $record = {};
    }

    $self->_debug(4, 'dump: ', Data::Dumper::Dumper($record)) if($self->{options}->{debug});

    return($record);
}

sub _store_namespace { $_[0]->_debug; $_[0]->_store_record($_[1], $_[0]->{namespace}) }
sub _store_root      { $_[0]->_debug; $_[0]->_store_record($_[1], $_[0]->{root}) }

sub _store_record
{
    my $self    = shift;
    my $share   = defined($_[0]) ? (ref($_[0]) eq 'HASH' ? shift() : croak('Apache::SharedMem: unexpected error, wrong data type')) : croak('Apache::SharedMem; unexpected error, missing argument');
    my $ipc_obj = shift;

    $self->_debug(4, 'dump: ', Data::Dumper::Dumper($share)) if($self->{options}->{debug});

    my $serialized;

    # freeze the shared block
    eval { $serialized = freeze($share) };
    confess("Apache::SharedMem: Problem while the serialization of shared data. Storable error: $@") if $@;
    confess("Apache::SahredMem: Problem while the serialization of shared data.") unless(defined $serialized && $serialized ne '');

    $self->_debug(4, 'storable src: ', $serialized);

    # store the serialized data
    eval { $ipc_obj->store($serialized) };
    confess("Apache::SharedMem: Problem storing share segment. IPC::ShareLite error: $@") if $@;

    return($share);
}

sub _debug
{
    return() unless($_[0]->{options}->{debug});
    my $self  = shift;
    my $dblvl = defined($_[0]) && $_[0] =~ /^\d$/ ? shift : 1;
    printf(STDERR "### DEBUG %s method(%s) pid[%s]: %s\n", (caller())[0], (split(/::/, (caller(1))[3]))[-1], $$, join('', @_)) if($self->{options}->{debug} >= $dblvl);
}

sub _set_error
{
    my $self = shift;
    $self->{__last_error__} = join('', @_);
    $self->_debug($self->error);
}

sub _unset_error
{
    my $self = shift;
    $self->{__last_error__} = '';
}

sub _set_status
{
    my $self = shift;
    $self->{__status__} = defined $_[0] ? $_[0] : '';
    $self->_debug("setting status to $_[0]");
}

1;

=pod

=head1 AUTHOR

Olivier Poitrey E<lt>rs@rhapsodyk.netE<gt>

=head1 LICENCE

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or (at
your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
General Public License for more details.

You should have received a copy of the GNU General Public License
along with the program; if not, write to the Free Software
Foundation, Inc. :

59 Temple Place, Suite 330, Boston, MA 02111-1307

=head1 COPYRIGHT

Copyright (C) 2001 - Olivier Poitrey E<lt>rs@rhapsodyk.netE<gt>
