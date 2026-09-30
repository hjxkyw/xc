use lib 'lib', 't/lib';
use XtplCorpus;

# xtpl's corpus, part 2 of 3: xtpl's own tests, 38 to 58. 51_legacy, among
# them, is skipped, and this part checks that it is there.
# The checks are in t/lib/XtplCorpus.rakumod; the corpus is in three parts so
# that the runner can run them at once.
my @files = |dir('xtpl/tests').grep({ .extension eq 'xtpl' && .basename ge '38' });
corpus-check(@files, :skips);
