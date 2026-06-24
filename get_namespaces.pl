use lib '.';
use netbackup;
use strict;
use warnings;
use Getopt::Long qw(GetOptions);

sub printUsage {
    print "\nUsage : perl get_namespaces.pl -nbmaster <host> -username <user> -password <pass> [-domainname <dom>] [-domaintype <type>] [--verbose]\n\n";
    die;
}

my $fqdn_hostname;
my $username;
my $password;
my $domainname;
my $domaintype;
my $verbose;

GetOptions(
    'nbmaster=s'  => \$fqdn_hostname,
    'username=s'  => \$username,
    'password=s'  => \$password,
    'domainname=s'=> \$domainname,
    'domaintype=s'=> \$domaintype,
    'verbose'     => \$verbose
) or printUsage();

if (!$fqdn_hostname || !$username || !$password) {
    printUsage();
}

if ($verbose) {
    print "\nReceived the following parameters : \n";
    print " FQDN Hostname : $fqdn_hostname\n";
    print " Username      : $username\n";
    print " Password      : $password\n";
    if ($domainname) { print " Domain Name   : $domainname\n"; }
    if ($domaintype) { print " Domain Type   : $domaintype\n"; }
}

print "\n";

my $myToken;
if ($domainname && $domaintype) {
    $myToken = netbackup::login($fqdn_hostname, $username, $password, $domainname, $domaintype);
} else {
    $myToken = netbackup::login($fqdn_hostname, $username, $password);
}

my $jsonstring = netbackup::getNamespaces($fqdn_hostname, $myToken);
print "\nNetBackup Kubernetes Namespaces:\n";
print $jsonstring;

netbackup::logout($fqdn_hostname, $myToken);
print "\n";
