use lib 'lib', 't/lib';
use XtplCorpus;

# xtpl's corpus, part 1 of 3: xtpl's own tests, 01 to 37.
# The checks are in t/lib/XtplCorpus.rakumod; the corpus is in three parts so
# that the runner can run them at once.
my @files = |dir('xtpl/tests').grep({ .extension eq 'xtpl' && .basename lt '38' });
corpus-check(@files);
