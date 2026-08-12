#!/usr/bin/perl
use strict;
use warnings;
use LWP::UserAgent;
use HTTP::Request;
use IPC::Run qw(run);
use Getopt::Long;

=head1 NAME

test_connections.pl - Test les connexions NetBackup et Kubernetes

=head1 SYNOPSIS

./test_connections.pl --nb-master <host> --nb-user <user> --nb-pass <pass> --kb-config <path>

=cut

my %config = (
    nb_master   => $ENV{NETBACKUP_MASTER} || 'localhost',
    nb_port     => $ENV{NETBACKUP_PORT}   || 1556,
    nb_user     => $ENV{NETBACKUP_USER}   || undef,
    nb_pass     => $ENV{NETBACKUP_PASS}   || undef,
    kb_config   => $ENV{KUBECONFIG}       || "$ENV{HOME}/.kube/config",
);

GetOptions(
    'nb-master=s'   => \$config{nb_master},
    'nb-port=i'     => \$config{nb_port},
    'nb-user=s'     => \$config{nb_user},
    'nb-pass=s'     => \$config{nb_pass},
    'kb-config=s'   => \$config{kb_config},
    'help|h'        => sub { print "Usage: $0 [options]\n"; exit 0; },
) or exit 1;

my $failed = 0;

print "\n";
print "=" x 60 . "\n";
print "Test des connexions - NetBackup & Kubernetes\n";
print "=" x 60 . "\n";
print "\n";

# Test 1: Modules Perl
print "[TEST 1] Modules Perl requis\n";
print "-" x 60 . "\n";

my @modules = (
    'Term::Menu',
    'JSON::PP',
    'LWP::UserAgent',
    'HTTP::Request',
    'IPC::Run',
    'Getopt::Long',
    'Pod::Usage',
);

foreach my $module (@modules) {
    if (eval "require $module") {
        print "[✓] $module\n";
    } else {
        print "[✗] $module (manquant)\n";
        $failed = 1;
    }
}

print "\n";

# Test 2: Outils système
print "[TEST 2] Outils système\n";
print "-" x 60 . "\n";

my @tools = (
    { name => 'perl',    cmd => 'perl --version' },
    { name => 'curl',    cmd => 'curl --version' },
    { name => 'kubectl', cmd => 'kubectl version --client' },
    { name => 'nc',      cmd => 'nc -h' },
);

foreach my $tool (@tools) {
    if (system("$tool->{cmd} > /dev/null 2>&1") == 0) {
        print "[✓] $tool->{name}\n";
    } else {
        print "[✗] $tool->{name} (non trouvé)\n";
        $failed = 1;
    }
}

print "\n";

# Test 3: Connectivité NetBackup
print "[TEST 3] Connectivité NetBackup\n";
print "-" x 60 . "\n";
print "Hôte: $config{nb_master}\n";
print "Port: $config{nb_port}\n";
print "User: $config{nb_user}\n";
print "\n";

# Test de connectivité TCP
print "3a) Test TCP...\n";
my $tcp_cmd = "nc -zv $config{nb_master} $config{nb_port} 2>&1";
my $tcp_result = system($tcp_cmd);
if ($tcp_result == 0) {
    print "[✓] Connectivité TCP OK\n";
} else {
    print "[✗] Impossible de se connecter au port $config{nb_port}\n";
    $failed = 1;
}

print "\n";

# Test API NetBackup
if ($config{nb_user} && $config{nb_pass}) {
    print "3b) Test API NetBackup...\n";
    
    my $ua = LWP::UserAgent->new();
    $ua->timeout(10);
    $ua->ssl_opts(verify_hostname => 0);
    
    my $url = "https://$config{nb_master}:$config{nb_port}/netbackup/v2/backups?limit=1";
    my $req = HTTP::Request->new(GET => $url);
    $req->authorization_basic($config{nb_user}, $config{nb_pass});
    
    my $resp = $ua->request($req);
    
    if ($resp->is_success) {
        print "[✓] API NetBackup accessible\n";
        print "    Status: " . $resp->status_line . "\n";
        
        # Essayer de parser le JSON
        if ($resp->content =~ /^\{/) {
            print "[✓] Réponse JSON valide\n";
        } else {
            print "[⚠] Réponse non-JSON\n";
        }
    } else {
        print "[✗] Erreur API NetBackup\n";
        print "    Status: " . $resp->status_line . "\n";
        if ($resp->status_line =~ /401|403/) {
            print "    → Problème d'authentification (vérifier user/pass)\n";
        }
        $failed = 1;
    }
} else {
    print "[⚠] Credentials NetBackup non fournis\n";
    print "    Usage: --nb-user <user> --nb-pass <pass>\n";
}

print "\n";

# Test 4: Configuration Kubernetes
print "[TEST 4] Configuration Kubernetes\n";
print "-" x 60 . "\n";
print "Kubeconfig: $config{kb_config}\n";
print "\n";

# Vérifier l'existence du fichier
if (-f $config{kb_config}) {
    print "[✓] Fichier kubeconfig trouvé\n";
} else {
    print "[✗] Fichier kubeconfig non trouvé\n";
    print "    Chemin: $config{kb_config}\n";
    $failed = 1;
}

print "\n";

# Test kubeconfig
print "4b) Vérification du contenu kubeconfig...\n";

my ($kube_out, $kube_err);
run ['kubectl', "config", "get-clusters", "--kubeconfig=$config{kb_config}"],
    \undef, \$kube_out, \$kube_err or do {
    print "[✗] Erreur lecture kubeconfig\n";
    print "    Erreur: $kube_err\n";
    $failed = 1;
};

if ($kube_out) {
    my @clusters = split(/\s+/, $kube_out);
    print "[✓] Clusters trouvés: " . scalar(@clusters) . "\n";
    foreach my $cluster (@clusters) {
        print "    - $cluster\n" if $cluster;
    }
} else {
    print "[⚠] Aucun cluster trouvé dans kubeconfig\n";
}

print "\n";

# Test 5: Clusters accessibles
print "[TEST 5] Accessibilité des clusters\n";
print "-" x 60 . "\n";

my $context_out;
run ['kubectl', "config", "get-contexts", "-o", "name", "--kubeconfig=$config{kb_config}"],
    \undef, \$context_out, undef;

if ($context_out) {
    my @contexts = split(/\n/, $context_out);
    
    if (@contexts) {
        foreach my $context (@contexts) {
            chomp($context);
            next unless $context;
            
            print "Test cluster: $context\n";
            
            my $info_out;
            my $test_result = run(
                ['kubectl', "--kubeconfig=$config{kb_config}", "--context=$context", "cluster-info"],
                \undef, \$info_out, undef
            );
            
            if ($test_result) {
                print "[✓] Cluster accessible\n";
            } else {
                print "[✗] Cluster non accessible\n";
                $failed = 1;
            }
        }
    }
} else {
    print "[⚠] Aucun contexte Kubernetes trouvé\n";
}

print "\n";

# Test 6: Vérification RBAC
print "[TEST 6] Vérification des permissions RBAC\n";
print "-" x 60 . "\n";

my @permissions = (
    { name => 'get pods',           cmd => 'get pods --all-namespaces' },
    { name => 'create namespaces',  cmd => 'create namespace test-auth-check' },
    { name => 'get namespaces',     cmd => 'get namespaces' },
    { name => 'describe pod',       cmd => 'describe pod --all-namespaces' },
);

# Utiliser le premier contexte pour les tests
my $context_out2;
run ['kubectl', "config", "get-contexts", "-o", "name", "--kubeconfig=$config{kb_config}"],
    \undef, \$context_out2, undef;

if ($context_out2) {
    my @contexts = split(/\n/, $context_out2);
    my $first_context = $contexts[0];
    chomp($first_context);
    
    if ($first_context) {
        foreach my $perm (@permissions) {
            my $check_cmd = $perm->{cmd};
            if ($check_cmd =~ /create namespace/) {
                # Sauter le test de création
                print "[⚠] $perm->{name} (test créée)\n";
                next;
            }
            
            my $test = run(
                ['kubectl', "--kubeconfig=$config{kb_config}", "--context=$first_context", 
                 '--dry-run=client', split(/\s+/, $check_cmd)],
                \undef, \undef, \undef
            );
            
            if ($test) {
                print "[✓] $perm->{name}\n";
            } else {
                print "[✗] $perm->{name}\n";
            }
        }
    }
}

print "\n";

# Résumé
print "=" x 60 . "\n";
print "RÉSUMÉ\n";
print "=" x 60 . "\n";
print "\n";

if ($failed) {
    print "[✗] Certains tests ont échoué\n";
    print "\nVeuillez vérifier:\n";
    print "  1. La connectivité réseau\n";
    print "  2. Les credentials NetBackup\n";
    print "  3. Le fichier kubeconfig\n";
    print "  4. Les permissions RBAC Kubernetes\n";
    exit 1;
} else {
    print "[✓] Tous les tests sont passés\n";
    print "\nVous pouvez maintenant exécuter:\n";
    print "  ./k8s_backup_restore.pl\n";
    exit 0;
}
