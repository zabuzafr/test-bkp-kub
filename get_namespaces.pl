use lib '.';
use netbackup;
use strict;
use warnings;
use Getopt::Long qw(GetOptions);

# ... (paramètres identiques à get_nb_jobs.pl) ...

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
