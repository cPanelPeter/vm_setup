#!/usr/local/cpanel/3rdparty/bin/perl

# vm_setup.pl

use strict;
use warnings;
use Getopt::Long;
use Fcntl;
$| = 1;

my $VERSION = '0.6.2';

my ($ip, $natip, $help, $fast, $full, $force, $cltrue, $sethostname, $answer, $verbose, $hostname, $OS_TYPE,$OS_RELEASE,$OS_VERSION);
our $spincounter;
my $InstPHPSelector=0;
my $InstCageFS=0;

GetOptions (
	"help" => \$help,
	"verbose" => \$verbose,
	"full" => \$full,
	"fast" => \$fast,
	"force" => \$force,
	"installcl" => \$cltrue,
	"sethostname" => \$sethostname,
);

if ($help) {
    help();
}

print "\nVM Server Setup Script\n" .  "Version: $VERSION\n" .  "\n";

if ($sethostname) { 
	set_hostname();
	print "\n";
	exit;
}

if (-e "/root/vmsetup.lock") {
    if (!$force) {
        print "/root/vmsetup.lock exists. Script may have already run. --force bypasses.\n";
        exit;
    } 
    else {
        print "/root/vmsetup.lock exists. --force passed. Ignoring...\n";
    }
}
if($full) {
    print "--full passed. Passing y to all optional setup options.\n\n";
    chomp ($answer="y");
}
if($fast) {
    print "--fast passed. Skipping all optional setup options.\n\n";
    chomp ($answer="n");
}
#if($cltrue) { 
#    print "--installcl passed. Skipping --fast and adding --full setup options.\n\n";
#    chomp ($answer="y");
#}

# and go
create_lockfile();
add_resolvers();
yum_install_prereqs();
# generate random password (uses pwgen - installed in prereqs)
my $rndpass = &random_pass();  
set_hostname();
set_sysconfig_net();
fix_mainip();
create_whostmgrft();
correct_wwwacctconf();
fix_etc_hosts();
fix_screenperms();
make_accesshash();
install_CDBfile();
fix_pureftpd();
update_tweak_settings();
create_test_acct();
adding_aliases();

# upcp
if (!$full && !$fast) { 
   print "would you like to run upcp now? [n]: ";
   chomp ($answer = <STDIN>);
}
if ($answer eq "y") {
    print "\nrunning upcp ";
    system_formatted ('/scripts/upcp');
}

# running another check_cpanel_rpms
if (!$full && !$fast) { 
   print "\nwould you like to run check_cpanel_rpms now? [n]: ";
   chomp ($answer = <STDIN>);
}
if ($answer eq "y") {
    print "\nrunning check_cpanel_rpms  ";
    system_formatted ('/scripts/check_cpanel_rpms --fix');
}

update_motd();
disable_cphulkd();
update_license();
install_cloudlinux();
restart_cpsrvd();

# exit cleanly
print "\nSetup complete\n\n";
system_formatted ('cat /etc/motd');
print "\n"; 
if ($cltrue) { 
    print "\n\nCloudLinux installed! A reboot is required!\n\n";
    print "After the server has been rebooted, A cron job will run to complete the installation\n";
    print "of CageFS, PHP Selector and other updates.  Then the crontab entry will be removed.\n";
    print "Note: CageFS and PHP Selector will not function until a reboot occurs to install the new kernel.\n";
    print "Would you like to reboot now? [y/N]: ";
    my $reboot_now = <STDIN>;
    chomp($reboot_now);
    if ($reboot_now eq "") { 
	    # Do nothing - ENTER was pressed
    }
    $reboot_now = uc($reboot_now);
    if ($reboot_now eq "Y") { 
   	    system_formatted ("reboot");
    }
    print "Reboot cancelled by admin!. Reboot is still required or CageFS/PHP Selector will not function!\n";
}
else { 
	print "\n\nYou should log out and back in.\n\n";
}

exit;

sub print_formatted {
    my @input = split /\n/, $_[0];
	if ($verbose) { 
	    foreach (@input) { print "    $_\n"; }
	}
    else { 
        &spin;
    }
}

sub system_formatted {
    open (my $cmd, "-|", "$_[0]");
    while (<$cmd>) {
        print_formatted("$_");
    }
    close $cmd;
}

sub random_pass { 
	my $password_length=25;
	my $password;
	my $_rand;
	my @chars = split(" ", "
      a b c d e f g h j k l m 
      n o p q r s t u v w x y 
      z 1 2 3 4 5 6 7 8 9 Z Y 
      X W V U T S R Q P N M L 
      K J H G F E D C B A "
   );
    my $pwgen_installed=qx[ yum list installed | grep 'pwgen' ];
    if ($pwgen_installed) { 
        print "\npwgen installed successfully, using it to generate random password\n";
        $password = `pwgen -Bs 15 1`;
    } 
    else {     
        print "pwgen didn't install successfully, using internal function to generate random password\n";
	    srand;
	    my $key=@chars;
	    for (my $i=1; $i <= $password_length ;$i++) {
		    $_rand = int(rand $key);
		    $password .= $chars[$_rand];
	    }
    }
	return $password;
}

sub get_os_info {
    my $ises = 0;
    my $version;
    my $os      = "UNKNOWN";
    my $release = "UNKNOWN";
    my $os_release_file;
    foreach my $test_release_file ( 'CentOS-release', 'redhat-release', 'system-release' ) {
        if ( -e '/etc/' . $test_release_file ) {
            if ( ( ($os) = $test_release_file =~ m/^([^\-_]+)/ )[0] ) {
                $os = lc $os;
                $os_release_file = '/etc/' . $test_release_file;
                if ( $os eq 'system' ) {
                    $os = 'amazon';
                }
                last;
            }
        }
    }
    if ( open my $fh, '<', $os_release_file ) {
        my $line = readline $fh;
        close $fh;
        chomp $line;
        if ( length $line >= 4 ) { $release = $line; }
        if ( $line =~ m/(?:Corporate|Advanced\sServer|Enterprise|Amazon)/i ) { $ises    = 1; }
        elsif ( $line =~ /CloudLinux|CentOS/i ) { $ises    = 2; }
        if ( $line =~ /(\d+\.\d+)/ ) { $version = $1; }
        elsif ( $line =~ /(\d+)/ )      { $version = $1; }
        if ( $line =~ /(centos|cloudlinux|amazon)/i ) { $os = lc $1; }
    }
    return ( $release, $os, $version, $ises );
}

sub spin {
    my %spinner = ( '|' => '/', '/' => '-', '-' => '\\', '\\' => '|' );
    $spincounter = ( !defined $spincounter ) ? '|' : $spinner{$spincounter};
    print STDERR "\b$spincounter";
}

sub add_resolvers { 
    print "\nadding resolvers ";
    unlink '/etc/resolv.conf';
    sysopen (my $etc_resolv_conf, '/etc/resolv.conf', O_WRONLY|O_CREAT) or
        die print_formatted ("$!");
        print $etc_resolv_conf "search cpanel.net\n" . "nameserver 208.74.121.50\n" . "nameserver 208.74.121.103\n";
    close ($etc_resolv_conf);
}

sub set_hostname { 
    # generate unique hostnames from OS type, Version and cPanel Version info and time.
    ($OS_RELEASE, $OS_TYPE,$OS_VERSION) = get_os_info();
    my $time=time;
    my %ostype = (
            "centos" => "c",
            "cloudlinux" => "cl",
    );
    my $Flavor = $ostype{$OS_TYPE};
    my $versionstripped = $OS_VERSION;
    $versionstripped =~ s/\.//g;
    my $cpVersion=qx[ cat /usr/local/cpanel/version ];
    chomp($cpVersion);
    $cpVersion =~ s/\./-/g;
    $cpVersion = substr($cpVersion,3);
    $hostname = $Flavor.$versionstripped."-".$cpVersion."-".$time.".cpanel.vm";

    print "\nsetting hostname to $hostname  ";
    # Now create a file in /etc/cloud/cloud.cfg.d/ called 99_hostname.cfg
    sysopen (my $cloud_cfg, '/etc/cloud/cloud.cfg.d/99_hostname.cfg', O_WRONLY|O_CREAT) or
	    die print_formatted ("$!");
	    print $cloud_cfg "#cloud-config\n" . 
            "preserve_hostname: true\n" . 
            "manage_etc_hosts: false\n";
    close ($cloud_cfg);  
    system_formatted ("/usr/local/cpanel/bin/set_hostname $hostname");
}

sub create_lockfile { 
    print "\ncreating lock file "; 
    system_formatted ("touch /root/vmsetup.lock");
}

sub yum_install_prereqs { 
    print "\ninstalling utilities via yum [mtr nmap telnet nc vim s3cmd bind-utils pwgen jwhois dev git pydf]  ";
    system_formatted ("yum install mtr nmap telnet nc s3cmd vim bind-utils pwgen jwhois dev git pydf -y");
}

sub set_sysconfig_net { 
    print "\nupdating /etc/sysconfig/network  ";
    unlink '/etc/sysconfig/network';
    sysopen (my $etc_network, '/etc/sysconfig/network', O_WRONLY|O_CREAT) or
        die print_formatted ("$!");
        print $etc_network "NETWORKING=yes\n" .
                     "NOZEROCONF=yes\n" .
                     "HOSTNAME=$hostname\n";
    close ($etc_network);

    if (-e("/var/cpanel/cpnat")) { 
        chomp ( $ip = qx(cat /var/cpanel/cpnat | awk '{print\$2}') );
        chomp ( $natip = qx(cat /var/cpanel/cpnat | awk '{print\$1}') );
    }
}

sub fix_mainip { 
    # fix /var/cpanel/mainip file because for some reason it has an old value in it
    system_formatted ("ip=`cat /etc/wwwacct.conf | grep 'ADDR ' | awk '{print \$2}'`; echo -n \$ip > /var/cpanel/mainip");
}

sub create_whostmgrft { 
    # create .whostmgrft
    print "\ncreating /etc/.whostmgrft  ";
    sysopen (my $etc_whostmgrft, '/etc/.whostmgrft', O_WRONLY|O_CREAT) or
        die print_formatted ("$!");
    close ($etc_whostmgrft);
}

sub correct_wwwacctconf { 
    print "\ncorrecting /etc/wwwacct.conf  ";
    unlink '/etc/wwwacct.conf';
    sysopen (my $etc_wwwacct_conf, '/etc/wwwacct.conf', O_WRONLY|O_CREAT) or
        die print_formatted ("$!");
        print $etc_wwwacct_conf "HOST $hostname\n" .
                                "ADDR $natip\n" .
                                "HOMEDIR /home\n" .
                                "ETHDEV eth0\n" .
                                "NS ns1.os.cpanel.vm\n" .
                                "NS2 ns2.os.cpanel.vm\n" .
                                "NS3\n" .
                                "NS4\n" .
                                "HOMEMATCH home\n" .
                                "NSTTL 86400\n" .
                                "TTL 14400\n" .
                                "DEFMOD paper_lantern\n" .
                                "SCRIPTALIAS y\n" .
                                "CONTACTPAGER\n" .
                                "CONTACTEMAIL\n" .
                                "LOGSTYLE combined\n" .
                                "DEFWEBMAILTHEME paper_lantern\n";
    close ($etc_wwwacct_conf);
}

sub fix_etc_hosts {
    print "\ncorrecting /etc/hosts  ";
    unlink '/etc/hosts';
    sysopen (my $etc_hosts, '/etc/hosts', O_WRONLY|O_CREAT) or
        die print_formatted ("$!");
        print $etc_hosts "127.0.0.1		localhost localhost.localdomain localhost4 localhost4.localdomain4\n" .
                        "::1		localhost localhost.localdomain localhost6 localhost6.localdomain6\n" .
                        "$ip		daily $hostname\n";
    close ($etc_hosts);
}

sub fix_screenperms { 
    print "\nfixing screen perms  ";
    system_formatted ('/bin/rpm --setugids screen && /bin/rpm --setperms screen');
}

sub make_accesshash {
	print "\nCreating api_token and saving it to /root/.access_token...\n";
	system_formatted ('whmapi1 api_token_create token_name=root_access_token | tee /root/.access_token');
	print "\nMake sure to remove /root/.access_token once you have used it!\n";
    print "\n\nPress any key to continue.";
	my $anykey=<STDIN>;
}

sub install_CDBfile {
    print "\nInstalling CDB_file.pm Perl Module  ";
    system_formatted ('/usr/local/cpanel/bin/cpanm --force CDB_File');
}

sub update_tweak_settings {
    print "\nUpdating tweak settings (cpanel.config)  ";
    system_formatted ("/usr/sbin/whmapi1 set_tweaksetting key=allowremotedomains value=1");
    system_formatted ("/usr/sbin/whmapi1 set_tweaksetting key=allowunregistereddomains value=1");
}

sub create_test_acct {
    print "\ncreating test account - cptest  ";
    if (-e("/var/cpanel/packages/my_package")) {
        unlink("/var/cpanel/packages/my_package");
    }
    system_formatted ('/usr/sbin/whmapi1 createacct username=cptest domain=cptest.tld password=" . $rndpass ." pkgname=my_package savepkg=1 maxpark=unlimited maxaddon=unlimited');

    print "\ncreating test email - testing\@cptest.tld  ";
    system_formatted ('/usr/bin/uapi --user=cptest Email add_pop email=testing@cptest.tld password=" . $rndpass . "');

    print "\ncreating test database - cptest_testdb  ";
    system_formatted ("/usr/bin/uapi --user=cptest Mysql create_database name=cptest_testdb");

    print "\ncreating test db user - cptest_testuser  ";
    system_formatted ("/usr/bin/uapi --user=cptest Mysql create_user name=cptest_testuser password=". $rndpass );

    print "\nadding all privs for cptest_testuser to cptest_testdb  ";
    system_formatted ("/usr/bin/uapi --user=cptest Mysql set_privileges_on_database user=cptest_testuser database=cptest_testdb privileges='ALL PRIVILEGES'");
}

sub adding_aliases {
    my $exists=qx[ grep 'aliases.txt' /root/.bash_profile ];
    return if ($exists);  
    print "\nCreating /root/.bash_profile aliases ";
    if (-e("/root/.bash_profile")) {
        # Backup the current one if it exists. 
        system_formatted ("cp -rfp /root/.bash_profile /root/.bash_profile.vmsetup");
    }
    # Append.
    open(roots_bashprofile, ">>/root/.bash_profile") or die print_formatted ("$!");
    print roots_bashprofile <<EOF;
    source /dev/stdin <<< "\$(curl -s https://ssp.cpanel.net/aliases/aliases.txt)"
EOF
    close (roots_bashprofile);
}

sub update_motd {
    print "\nupdating /etc/motd  ";
    unlink '/etc/motd';
    my $etc_motd;
    sysopen ($etc_motd, '/etc/motd', O_WRONLY|O_CREAT) or die print_formatted ("$!");
    print $etc_motd "VM Setup Script created the following test accounts:\n\n" .
	    "WHM: user: root - pass: cpanel1\n" .
	    "cPanel: user: cptest - pass: " . $rndpass . "\n(Domain: cptest.tld cPanel Account: cptest)\n" .
	    "Webmail: user: testing\@cptest.tld - pass: " . $rndpass . "\n\n" . 
    
        "WHM - https://" . $ip . ":2087\n" . 
        "cPanel - https://" . $ip . ":2083\n" . 
        "Webmail - https://" . $ip . ":2096\n";
    close ($etc_motd);
}

sub disable_cphulkd {
    print "\ndisabling cphulkd  ";
    system_formatted ('whmapi1 disable_cphulk');
}

sub update_license {
    print "\nupdating cpanel license  ";
    system_formatted ('/usr/local/cpanel/cpkeyclt');
}

sub install_cloudlinux {
    if ($OS_TYPE eq "cloudlinux" and !$force) { 
        print "\nCloudLinux already detected, skipping CloudLinux install."; 
	    # No need to install CloudLinux. It's already installed
	    $cltrue = 0;
    }
    if ($cltrue) { 
	    # Remove /var/cpanel/nocloudlinux touch file (if it exists)
	    if (-e("/var/cpanel/nocloudlinux")) { 
            print "\nremoving /var/cpanel/nocloudlinux touch file  ";
		    unlink("/var/cpanel/nocloudlinux");
	    }
        print "\ndownloading cldeploy shell file  ";
	    system_formatted ("wget http://repo.cloudlinux.com/cloudlinux/sources/cln/cldeploy");
        $verbose = 1;
        print "\nReady to execute cldeploy shell file (Note: this runs a upcp and can take time)";
        print "\nPress any key to continue.";
	    my $anykey=<STDIN>;
        system_formatted ("echo y | sh cldeploy -k 42-2efe234f2ae327824e879a2bec87fc59");
        $verbose = 0;
		# Everything else will be handled by the temporary vmsetup_cron.sh script.
		# which is executed upon reboot (required).  
	    # Create /root/vmsetup_cron.sh file here.  
	    my $createdate = `date`;
	    chomp($createdate);
	    sysopen (my $vmsetup_cron, '/root/vmsetup_cron.sh', O_WRONLY|O_CREAT) or die print_formatted ("$!");
        print $vmsetup_cron "#!/bin/sh
# Created by vm_setup.pl on $createdate
echo \"vmsetup_cron.sh script started at `uptime`\" >> /root/vmsetup_cron.log
LVE=`uname -r | grep 'lve'`
if [ \$\{LVE\} ]
then
	echo \"changing to root\" >> /root/vmsetup_cron.log
    cd /root
    # Install cagefs
	echo \"running install cagefs\" >> /root/vmsetup_cron.log
    yum -y install cagefs
    # CageFS Init
	echo \"running init cagefs\" >> /root/vmsetup_cron.log
    /usr/sbin/cagefsctl --init
    # Install PHP Selector
	echo \"running install php selector\" >> /root/vmsetup_cron.log
    yum -y groupinstall alt-php
    # Update CageFS and LVE Manager
	echo \"running update cagefs and lvemanager\" >> /root/vmsetup_cron.log
    yum -y update cagefs lvemanager
    # set hostname
	echo \"setting hostname\" >> /root/vmsetup_cron.log
    /root/vm_setup.pl --sethostname
    # Remove crontab entry
	echo \"cleaning up\" >> /root/vmsetup_cron.log
    crontab -l | grep -v 'vmsetup_cron' | crontab -
    # Remove /root/vmsetup_cron.sh file 
    rm -f /root/vmsetup_cron.sh
else
	echo \"no LVE kernel found after reboot\" >> /root/vmsetup_cron.log
    echo \"CL Kernel not loaded/running!\"
fi
echo \"vmsetup_cron.sh script completed at `uptime`\" >> /root/vmsetup_cron.log
";
        close ($vmsetup_cron);
	    system_formatted ('chmod 755 /root/vmsetup_cron.sh');
	    # Now add entry to root's crontab
	    open my $fh, "| crontab -" or die "can't open crontab $!";
	    my $cron = qx[ crontab -l ];
	    print $fh "$cron\@reboot /root/vmsetup_cron.sh\n";
	    close $fh;
    }
}

sub restart_cpsrvd {
    print "\nRestarting cpsvrd  ";
    system_formatted ("/usr/local/cpanel/scripts/restartsrv_cpsrvd");
}

sub fix_pureftpd { 
    sysopen (my $pureftp_local, '/var/cpanel/conf/pureftpd/local', O_WRONLY|O_CREAT) or die print_formatted ("$!");
    print $pureftp_local "ForcePassiveIP: $ip\n";
    close ($pureftp_local);
    system_formatted("/usr/local/cpanel/scripts/setupftpserver pure-ftpd --force");
}

sub help { 
    print "Usage: perl vm_setup.pl [options]\n\n";
    print "Description: Performs a number of functions to prepare VMs (on service.cpanel.ninja) for immediate use. \n\n";
    print "Options: \n";
    print "-------------- \n";
    print "--force: Ignores previous run check\n";
    print "--fast: Skips all optional setup functions\n";
    print "--verbose: pretty self explanatory\n";
    print "--full: Passes yes to all optional setup functions\n";
    print "--installcl: Installs CloudLinux(can take a while and requires reboot)\n";
    print "Full list of things this does: \n";
    print "-------------- \n";
    print "- Installs common/useful packages\n";
    print "- Sets hostname\n";
    print "- Updates /var/cpanel/cpanel.config (Tweak Settings)\n";
    print "- Performs basic setup wizard\n";
    print "- Fixes /etc/hosts\n";
    print "- Fixes screen permissions\n";
    print "- Runs cpkeyclt\n";
    print "- Creates test account (with email and database)\n";
    print "- Disables cphulkd\n";
    print "- Creates access hash\n";
    print "- Updates motd\n";
    print "- Creates /root/.bash_profile with helpful aliases\n";
    print "- Runs upcp (optional)\n";
    print "- Runs check_cpanel_rpms --fix (optional)\n";
    print "- Downloads and runs cldeploy (Installs CloudLinux) --installcl (optional)\n";
    exit;
}

