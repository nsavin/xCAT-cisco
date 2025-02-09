#!/usr/bin/env perl
# vallard@benincosa.com
# vallard@cisco.com
# © 2011 Cisco Systems, Inc. All rights reserved.
# nsavin@griddynamics.com

package xCAT_plugin::ucs;
BEGIN
{
  $::XCATROOT = $ENV{'XCATROOT'} ? $ENV{'XCATROOT'} : '/opt/xcat';
}

#perl Libraries
use strict;
use LWP;
use XML::Simple;
use IO::Socket;
use Data::Dumper;
use Getopt::Long;
use Carp;
$XML::Simple::PREFERRED_PARSER='XML::Parser';

#xCAT libraries
use lib "$::XCATROOT/lib/perl";
use xCAT::Table;
use xCAT::Utils;
use xCAT::DBobjUtils;
use xCAT::SvrUtils;


my %powermap = (
    on      =>  'up',
    off     =>  'down',
    softoff => 'soft-shut-down',
    cycle   => 'cycle-immediate',
    'reset' => 'hard-reset-immediate',
    boot    => 'cycle-immediate',
);


=head1 NAME 

xCAT_plugin::ucs - A UCS plugin for xCAT

=cut


=head1 SYNOPSYS

xCAT_plugin::ucs really only works with xCAT.
put it in the /opt/xcat/lib/perl/xCAT_plugin directory

=cut


=head1 AUTHOR

Vallard Benincosa - L<http://benincosa.com>

Savin Nikita <nsavin@griddynamics.com>

=cut

=head1 FUNCTIONS

=cut


sub handled_commands {
  return {
    rpower => 'nodehm:power,mgt',
    getmacs => 'nodehm:getmac,mgt',
  };
}

=item preprocess_request

Used to handle service nodes.  We don't have support for this right now.
TODO: Test this with service nodes!

=cut

sub preprocess_request {
    	Getopt::Long::Configure("bundling");
    	Getopt::Long::Configure("no_pass_through");
	my $req = shift;
	# ignore this function for now and just return
	return [$req];
}


=item process_request 

This is the main entry point for the plugin.  The commands get handed
here and we process them based on what command was asked for.

=cut

sub process_request {
	# pass the getops to this function
    	Getopt::Long::Configure("bundling");
    	Getopt::Long::Configure("no_pass_through");
	my $request = shift;
	my $callback = shift;
	my $command = $request->{command}->[0];
    if ($request->{arg}) {
        @ARGV = @{$request->{arg}};
    } else {
        @ARGV = ();
    }
	

	if($command eq 'rpower'){
		power($request, $callback);
    }
    elsif ($command eq 'getmacs') {
        getmacs($request, $callback);
	}else{
		$callback->({error=>["$command is not yet supported for UCS"],errorcode=>1});
	}
	return;
}



### Finished xCAT API
#
### Interal logic


sub getmacs { 
	my $request = shift;
	my $callback = shift;
    my $mactab = xCAT::Table->new('mac',-create=>1);
    my $nrtab = xCAT::Table->new('noderes');
    if (!$nrtab) { 
		$callback->({error => ["Can't open noderes table"],errorcode=>1});
        return;
    }
    my $ucsm = buildNodes($request->{node}, $callback);
    my @node2dn = _profile2dn($ucsm);
    for my $gn (@node2dn) { 
        my %nodes = %{$gn->{nodes}};
        my $ucsm = $gn->{ucsm};
        for my $node (keys %nodes) {
            my $nent = $nrtab->getNodeAttribs($node,['primarynic','installnic']);
            my $mkey = $nent->{installnic} || $nent->{primarynic};
            if (!$mkey) { 
                $callback->({error=> ["please set noderes.installnic or noderes.primarynic for $node"], errorcode=>1});
                next;
            }
            if ($mkey !~ /^eth\d+$/) { 
                $callback->({error=> ["please set noderes.installnic or noderes.primarynic for $node in form eth1"], errorcode=>1});
                next;
            }

            my $s = $ucsm->get_scope($nodes{$node}{_profile}{dn}, 'vnicEther');
            my %mac;
            for my $ifdn (values %{$s->{outConfigs}}) {
                unless ($ifdn->{name} =~ /eth(\d+)$/) {
                    $ucsm->err("unknown intreface %s on node %s", $ifdn->{name}, $node);
                    next;
                }
                #TODO check interface presented and enabled
                $mac{$ifdn->{name}} = lc $ifdn->{addr};
            }
            
            if (not exists $mac{$mkey}) { 
                $ucsm->err("%s: can't find mac for %s", $node, $mkey);
                next;
            }
	        $callback->({node => [ {name => [$node], data => [{desc => [
                join ", ", values %mac], contents =>["used: ".$mac{$mkey}]}] } ]});

            $mactab->setNodeAttribs($node,{mac=>$mac{$mkey}});
                 
        }
        $ucsm->logout();
    }
    $mactab->close();
    $nrtab->close(); 
}

sub power {
	my $request = shift;
	my $callback = shift;
	# get additional arguments
	my $usage = sub {
		$callback->({data => 
			[
			"Usage: ",
			"   rpower " . $request->{noderange}->[0] . " on|off|stat|reset|boot|softoff|cycle"
			]
		});
		return;
	};

    my $help = 0;
	GetOptions(
		'h|?|help' => \$help,
	);
	if($help){ $usage->($callback); return }

	my $subcmd = shift( @ARGV);
	unless($subcmd){
		$callback->({error => ["No power action specified"],errorcode=>1});
		$usage->();
		return;
	}

	unless($subcmd =~ /on|off|stat|reset|boot|cycle|softoff/){
		$callback->({error => ["Invalid power action: $subcmd"],errorcode=>1});
		$usage->();
		return;
	}

    my $ucsm = buildNodes($request->{node}, $callback);
	if($subcmd =~ /stat/){
		powerStat($ucsm, $callback);
	}
    else{
		powerOp($ucsm, $callback, $subcmd);
	}
}


sub powerOp {
	my $ucsm = shift;
	my $callback = shift;
	my $op = shift; 
	unless($ucsm){
		return;
	}
    my $error = 0;
	foreach my $gn (@$ucsm){
        if ($error) {
            $gn->{ucsm}->logout();
            next;
        }
		my $xml = "<configConfMo ^^cookie^^ dn='' inHierarchical='no'><inConfig>\n";
        $xml .= "<lsPower dn='$_' state='$powermap{$op}' status='modified'/>\n" 
            for values %{$gn->{nodes}};
		$xml .= "</inConfig></configConfMo>\n";
        my $resp = $gn->{ucsm}->_request($xml);
        $gn->{ucsm}->logout();
        if ($resp->{errorCode}) {
            print Dumper $resp;
            $callback->({error => $resp->{errorDescr}});
            $error++;
        }
        else {
	        $callback->({node => [ {name => [$_], data => [{desc => ["$gn->{nodes}{$_}"], 
                contents =>[$op]}] } ]}) for keys %{$gn->{nodes}};
        }
	}	
}



sub powerStat {
	my $nh = shift;
	my $callback = shift;
	unless($nh){
		return;
	}
    my @res = _profile2dn($nh); 
	foreach my $gn (@res){
        my %nodes = %{$gn->{nodes}};
        my $blade = $gn->{ucsm}->get_dns(map {$_->{dn}} values %nodes);
        my $blade_out = $blade->{outConfigs}->{computeBlade};
        $blade_out = {$blade_out->{dn} => $blade_out} if $blade_out->{dn};
        $blade_out->{$_}{dn}=$_ for keys %$blade_out;
        my %cmap = map { $nodes{$_}{dn} => $_ } keys %nodes;
        for (values %$blade_out) {
            if (exists $cmap{$_->{dn}}) {
                my $node = $cmap{$_->{dn}};
            	$callback->({node => [ {
                    name => [$node], 
                    data => [{desc => ["$_->{dn}"], 
                    contents =>[$_->{operPower}]}],
                 }]});
            }
            else { 
			        $callback->({error=>"Unknown profile returned",errorcode=>1});
            }
        }
        $gn->{ucsm}->logout();
	}
}
  

sub _profile2dn { 
    my $nh = shift;
    my @res;
	foreach my $gn (@$nh){
        my %res;
        my %profile2n = map {$gn->{nodes}{$_} => $_ } keys %{$gn->{nodes}};
        my $profile = $gn->{ucsm}->get_dns(values %{$gn->{nodes}});
        my $profile_out = $profile->{outConfigs}->{lsServer};
        # if several records returned, it outputed as subhashes, if only
        # one - as flat hash
        $profile_out = {$profile_out->{dn} => $profile_out} if $profile_out->{dn};
        $profile_out->{$_}{dn}=$_ for keys %$profile_out;
        for (values %$profile_out) {
            if (exists $profile2n{$_->{dn}}) {
                my $node = $profile2n{$_->{dn}};
                my %n;
                $n{configState} = $_->{configState};
                $n{dn} = $_->{pnDn};
                $n{node} = $node;
                $n{_profile} = $_;
                if ($n{configState} =~ /applied/) {
                    $res{$node} = \%n;
                }
                else {
                    $n{configState} ||= 'UnknownState';
			        $gn->{ucsm}->err("%s in %s state and not ready", 
                        $node, $n{configState});
                }
            }
            else { 
			        $gn->{ucsm}->err("Unknown profile returned: %s", $_->{dn});
            }
        }
        my $profile_unexist = $profile->{outUnresolved}{dn};
        if ($profile_unexist) { 
        for (ref $profile_unexist eq 'ARRAY' ? @{$profile_unexist} : $profile_unexist) {
			$gn->{ucsm}->err("%s: %s: unexist", $profile2n{$_->{value}}, $_->{value});
        }
        }
        push @res, {ucsm=>$gn->{ucsm}, nodes=>\%res};
    }
    return @res;
}





sub buildNodes {
	my $nodes = shift;
	my $callback = shift;
	my $errors = 0;
	# build the right stuff here!
	my %nh; # the node hash
	

	my @tabs = qw(mp mpa);
	my %db = ();
	# open all the tables.
	for my $table (qw(mp mpa)) {
		$db{$table} = xCAT::Table->new($table);
		if(!$db{$table}){
			$callback->({error=>"Error opening $table table",errorcode=>1});
			return 0;
		}
	}	
	
	# first get the mpas.
	my $mph = $db{'mp'}->getNodesAttribs($nodes, [qw(mpa id)]);
	foreach my $node (@$nodes){
		unless($mph->{$node}->[0] && $mph->{$node}->[0]->{mpa}){
			$errors++;
			$callback->({error=>["$node: Please specify the UCS Manager in mp.mpa"],errorcode=>1});
			next;
		}

		unless($mph->{$node}->[0]->{id}){
			$callback->({error=>["$node: No management id specified.  Please change mp.id to be service profile"],errorcode=>1});
			next;	
		}

		my $id = $mph->{$node}->[0]->{id};
		
		my $ucsm_host = $mph->{$node}->[0]->{mpa};
        $nh{$ucsm_host} ||= { 
            ucsm => undef, 
            nodes =>{}, 
        }; 

		$nh{$ucsm_host}{nodes}{$node} = $id;
	}

	# now get the user and password for the mpas
	foreach my $ucsm (keys %nh){
		my $ent = $db{'mpa'}->getAttribs({mpa=>$ucsm},'username','password');		
		if (not $ent and $ent->{password} and $ent->{username}){
            $callback->({error=>["No username or password specified in mpa.{username,password} table.  Please specify a username and password"],errorcode=>1});
            $errors++;
            next;
		}else{
            $nh{$ucsm}{ucsm} = xCAT_plugin::ucs->new($callback, $ucsm, 
                $ent->{username}, $ent->{password}, $callback);
            if (!$nh{$ucsm}{ucsm}) {
                #login error
                delete $nh{$ucsm};
            }
		}
	}
	
	if($errors){
		return 0;
	}
	return [values %nh];
} 

### Working with UCSM
#

sub new { 
    my ($class, $callback, $host, $login, $password) = @_;
    my $self = { 
        host =>             $host,
        login =>            $login,
        password =>         $password,
        callback =>         $callback,
        _cookie =>          '',
    };
    #TODO error check
    bless $self, $class;
    $self->login();
    return $self;
}

sub login {
    my $self = shift;
	my $xmlcmd =sprintf "<aaaLogin inName='%s' inPassword='%s'></aaaLogin>", 
        $self->{login}, $self->{password};
    my $resp = $self->_request($xmlcmd);
	return $self->err("login failure: %s", $resp->{errorDescr}) if $resp->{errorDescr}; 
	$self->{_cookie} = $resp->{'outCookie'};
	return $self->{_cookie};
}

sub logout {
    my $self = shift;
    $self->_request(sprintf "<aaaLogout inCookie='%s' />", $self->{_cookie});
    return;
}

sub get_dns { 
    my $self = shift;
    my @dns = @_;
	my $xml = '<configResolveDns ^^cookie^^ inHierarchical="false">'."\n";
	$xml .= "<inDns>\n";
	$xml .= "<dn value=\"$_\"/>\n" for @dns; 
	$xml .= "</inDns>\n";
	$xml .= "</configResolveDns>\n";
    return $self->_request($xml);
}

sub get_scope { 
    my $self = shift;
    my ($dn, $class) = @_;
    my $xml = sprintf '<configScope ^^cookie^^ dn="%s" inClass="%s" inHierarchical="false"'.
        ' inRecursive="false"><inFilter></inFilter></configScope>', $dn, $class;
    return $self->_request($xml);
}

sub _request {
    my ($self, $cmd) = @_;
    $cmd =~ s/\^\^cookie\^\^/ cookie="$self->{_cookie}" /gs;
print " --> $cmd\n" if $ENV{DEBUG};
    my $browser = LWP::UserAgent->new();
	my $url = sprintf 'http://%s/nuova', $self->{host};
	my $xml_header = "<?xml version='1.0'?>";
	my $request = HTTP::Request->new(POST => $url);
	$request->content_type("application/x-www-form-urlencoded");
	$request->content($cmd);

	my $response = $browser->request($request);
	unless($response->is_success){
		return $self->err("xml fetch error: %s", $response->status_line);
	}
print " <-- ".$response->content."\n\n" if $ENV{DEBUG};
	my $parser = XML::Simple->new();
    my $xml = eval {$parser->XMLin($response->content, KeyAttr => 'dn')};
    return $self->err("parsing xml %s\n----\n%s\n----\n", $@, 
        $response->content) if $@;
    return $xml;
};

sub err { 
    my ($self, $msg) = (shift, shift);
    my @params = @_;
    my $msg = "%s: error ".$msg;
    $self->{callback}->({error=>[sprintf $msg, $self->{host}, @params], errorcode=>1});
    #TODO make error bubling
    return 0;  
}


1;
