use ExtUtils::MakeMaker;

WriteMakefile
(
    'NAME'		=> 'Apache::SharedMem',
    'VERSION_FROM'	=> 'lib/Apache/SharedMem.pm', # finds $VERSION
    'PREREQ_PM'		=> 
    {
        IPC::ShareLite => '0.06',
        Storable       => '1.006',
    },
    ($] >= 5.005 ?    ## Add these new keywords supported since 5.005
      (ABSTRACT_FROM => 'lib/Apache/SharedMem.pm',
       AUTHOR     => 'Olivier Poitrey <rs@rhapsodyk.net>') : ()),
);
