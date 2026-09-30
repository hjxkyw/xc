use lib 'lib', 't/lib';
use XtplCorpus;

# xtpl's corpus, part 3 of 3: xtpl's example programs, and xc's own self-test for an AppServer
# (run-protheus.raku), which has to be as clean as any of them.
# The checks are in t/lib/XtplCorpus.rakumod; the corpus is in three parts so
# that the runner can run them at once.
my @files = |dir('xtpl/examples').grep(*.d).map({ |dir($_).grep(*.extension eq 'xtpl') }),
            'protheus/xc_selftest.xtpl'.IO;
corpus-check(@files);
