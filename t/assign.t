package Test::AS::assign;

BEGIN
{
    use strict;
    use Test;
    plan tests => 8;
}


use Apache::SharedMem qw(:all);
ok(1);

my $share = new Apache::SharedMem;

$share->set('test'=>'teststring');
ok($share->status, SUCCESS);

ok($share->get('test'), 'teststring');

my $share2 = new Apache::SharedMem;
ok($share2->get('test'), 'teststring');

$share->delete('test');
ok($share->status, SUCCESS);
ok(!defined($share->get('test')));
ok(!$share2->exists('test'));

$share->release;
ok($share->status, SUCCESS);
