#!/usr/bin/env perl
# Author: Lee Katz <lkatz@cdc.gov>
# Uses Mash to create a database of distances
# Run this script with -h for help and usage.

use strict;
use warnings;
use Data::Dumper;
use Getopt::Long;
use File::Temp qw/tempdir tempfile/;
use File::Basename qw/basename dirname fileparse/;
use File::Copy qw/copy move/;
use POSIX qw/floor/;
use List::Util qw/min max/;
use Scalar::Util qw/looks_like_number/;

use threads;
use threads::shared;

use FindBin;
use lib "$FindBin::RealBin/../lib";
use Mashtree qw/logmsg @fastqExt @fastaExt @mshExt @richseqExt _truncateFilename $MASHTREE_VERSION/;
use Mashtree::Db;
use Bio::Tree::DistanceFactory;
use Bio::Matrix::IO;
use Bio::Tree::Statistics;
use Bio::SeqIO;

my %delta :shared=(); # change in amplitude for peak detection, for each fastq
my $scriptDir=dirname $0;
my $dbhLock :shared;  # Use this as a lock so that only one thread writes to the db at a time
my $abundanceFinderLock :shared; # a lock to limit min abundance finder instances
local $0=basename $0;

exit main();

sub main{
  my $settings={};
  GetOptions($settings,qw(help outfile|output=s tempdir=s numcpus=i genomesize=i mindepth|min-depth=i truncLength=i kmerlength=i sort-order=s sketch-size=i version)) or die $!;
  $$settings{numcpus}||=1;
  $$settings{truncLength}||=250;  # how long a genome name is
  $$settings{tempdir}||=tempdir("MASHTREE.XXXXXX",CLEANUP=>1,TMPDIR=>1);
  $$settings{'sort-order'}||="ABC";

  # Mash-specific options
  $$settings{genomesize}||=5000000;
  $$settings{mindepth}//=5;
  $$settings{kmerlength}||=21;
  $$settings{'sketch-size'}||=10000;

  # Make some settings lowercase
  for(qw(sort-order)){
    $$settings{$_}=lc($$settings{$_});
  }

  die usage() if($$settings{help});
  if($$settings{version}){
    print "Mashtree $MASHTREE_VERSION\n";
    return 0;
  }

  # "reads" are either fasta assemblies or fastq reads
  my @reads=@ARGV;
  die usage() if(@reads < 2);
  die "ERROR: need --outfile" if(!$$settings{outfile});

  # Check for prereq executables.
  for my $exe(qw(mash)){
    system("$exe -h > /dev/null 2>&1");
    die "ERROR: could not find $exe in your PATH" if $?;
  }

  # Distributed cpus if we have few genomes but high numcpus
  $$settings{cpus_per_mash}=floor($$settings{numcpus}/@reads);
  $$settings{cpus_per_mash}=1 if($$settings{cpus_per_mash} < 1);
  $$settings{numthreads}=min(scalar(@reads), $$settings{numcpus});

  #die Dumper [$$settings{cpus_per_mash},$$settings{numthreads},\@reads];
  #$$settings{cpus_per_mash}=1;
  #$$settings{numthreads}=$$settings{numcpus};

  logmsg "Temporary directory will be $$settings{tempdir}";
  logmsg "$0 on ".scalar(@reads)." files";

  my %seen;
  my @tmp;
  for my $reads(@ARGV){
    if(!-e $reads){
      die "ERROR: I could not find reads path at $reads";
    }
    my $basename=basename($reads);
    if($seen{$basename}++){
      logmsg "Skipping $reads: already seen $basename";
      next;
    }
    push(@tmp,$reads);
  }
  @reads=@tmp;

  my $sketches=sketchAll(\@reads,"$$settings{tempdir}",$settings);

  my $db = mashDistance($sketches,\@reads,$$settings{tempdir},$settings);

  logmsg "New file in $$settings{outfile}";
  move($db, $$settings{outfile});

  return 0;
}

# Run mash sketch on everything, multithreaded.
sub sketchAll{
  my($reads,$sketchDir,$settings)=@_;

  mkdir $sketchDir if(!-d $sketchDir);

  # Make an array of genomes that would distribute well
  # across threads.  For example, don't put all raw-read
  # genomes into a single thread and all the assemblies
  # into another.
  my %filesize=();
  for(@$reads){
    $filesize{$_} = -s $_;
  }
  my @sortedReads=sort {$filesize{$a} <=> $filesize{$b}} @$reads;
  my @threadArr=();
  for(my $i=0; $i<@sortedReads; $i++){
    # Since each genome is sorted smallest to leargest,
    # they can be sent round-robin to each thread to 
    # ensure balance.
    my $threadIndex = $i % $$settings{numcpus};
    push(@{ $threadArr[$threadIndex] }, $sortedReads[$i]);
  }

  # Initiate the threads
  my @thr;
  for(0..$$settings{numthreads}-1){
    $thr[$_]=threads->new(\&mashSketch,$sketchDir,$threadArr[$_],$settings);
  }

  my @mshList;
  for(@thr){
    my $mashfiles=$_->join;
    for my $file(@$mashfiles){
      push(@mshList,$file);
    }
  }

  return \@mshList;
}

# Individual mash sketch
sub mashSketch{
  my($sketchDir,$genomeArr,$settings)=@_;

  # If any file needs to be converted, it will end up in
  # this directory.
  my $tempdir=tempdir("$$settings{tempdir}/convertSeq.XXXXXX", CLEANUP=>1);

  my @msh;
  # $fastq is a misnomer: it could be any kind of accepted sequence file
  for my $fastq(@$genomeArr){
    my($fileName,$filePath,$fileExt)=fileparse($fastq,@fastqExt,@fastaExt,@richseqExt,@mshExt);

    # Unzip the file. This temporary file will
    # only exist if the correct extensions are detected.
    my $unzipped="$tempdir/".basename($fastq);
    $unzipped=~s/\.(gz|bz2?|zip)$//i;
    my $was_unzipped=0;
    # Don't bother unzipping if it's a fastq or fasta file b/c Mash can read those
    if(!grep {$_ eq $fileExt} (@fastqExt,@fastaExt)){
      if($fastq=~/\.gz$/i){
        system("gzip  -cd $fastq > $unzipped");
        die "ERROR with gzip  -cd $fastq" if $?;
        $was_unzipped=1;
      } elsif($fastq=~/\.bz2?$/i){
        system("bzip2 -cd $fastq > $unzipped");
        die "ERROR with bzip2 -cd $fastq" if $?;
        $was_unzipped=1;
      } elsif($fastq=~/\.zip$/i){
        system("unzip -p  $fastq > $unzipped");
        die "ERROR with unzip -p  $fastq" if $?;
        $was_unzipped=1;
      }
    }

    # If the file was uncompressed, parse the filename again.
    if($was_unzipped){
      $fastq=$unzipped;
      ($fileName,$filePath,$fileExt)=fileparse($fastq,@fastqExt,@fastaExt,@richseqExt,@mshExt);
    }

    # If we see a richseq (e.g., gbk or embl), then convert it to fasta
    # TODO If Mash itself accepts richseq, then consider
    # doing away with this section.
    if(grep {$_ eq $fileExt} @richseqExt){
      # Make a temporary fasta file, but it needs to have a
      # consistent name in case Mashtree is being run with
      # the wrapper for bootstrap values.
      # I can't exactly make a consistent filename in case
      # different mashtree invocations collide, so
      # I need to make a new temporary directory with a 
      # consistent filename.
      my $tmpfasta="$tempdir/$fileName$fileExt.fasta";
      my $in=Bio::SeqIO->new(-file=>$fastq);
      my $out=Bio::SeqIO->new(-file=>">$tmpfasta", -format=>"fasta");
      while(my $seq=$in->next_seq){
        $out->write_seq($seq);
      }
      logmsg "Wrote $tmpfasta";

      # Update our filename for downstream
      $fastq=$tmpfasta;
      ($fileName,$filePath,$fileExt)=fileparse($tmpfasta, @fastaExt);
    }

    # Do different things depending on fastq vs fasta
    my $sketchXopts="";
    if(grep {$_ eq $fileExt} @fastqExt){
      my $minDepth=determineMinimumDepth($fastq,$$settings{mindepth},$$settings{kmerlength},$settings);
      $sketchXopts.="-m $minDepth -g $$settings{genomesize} ";
    } elsif(grep {$_ eq $fileExt} @fastaExt) {
      $sketchXopts.=" ";
    } elsif(grep {$_ eq $fileExt} @mshExt){
      $sketchXopts.=" ";
    } else {
      logmsg "WARNING: I could not understand what kind of file this is by its extension ($fileExt): $fastq";
    }
      
    my $outPrefix="$sketchDir/".basename($fastq, @mshExt);

    # See if the user already mashed this file locally
    if(-e "$fastq.msh"){
      logmsg "Found locally mashed file $fastq.msh. I will use it.";
      copy("$fastq.msh","$outPrefix.msh");
    }
    if(grep {$_ eq $fileExt} @mshExt){
      logmsg "Input file is a sketch file itself and will be used as such: $fastq";
      copy($fastq, "$outPrefix.msh");
    }

    if(-e "$outPrefix.msh"){
      logmsg "WARNING: ".basename($fastq)." was already mashed.";
    } elsif(-s $fastq < 1){
      logmsg "WARNING: $fastq is a zero byte file. Skipping.";
      next;
    } else {
      logmsg "Sketching $fastq";
      my $sketchCommand="mash sketch -k $$settings{kmerlength} -s $$settings{'sketch-size'} $sketchXopts -o $outPrefix $fastq  1>&2";
      system($sketchCommand);
      die if $?;
    }

    push(@msh,"$outPrefix.msh");
  }

  system("rm -rf $tempdir");

  return \@msh;
}

# Parallelized mash distance
sub mashDistance{
  my($mshList,$reads,$outdir,$settings)=@_;

  # Make a list of names that will appear in the database
  # in exactly the right format.
  my @genomeName;

  # Make a temporary file with one line per mash file.
  # Helps with not running into the max number of command line args.
  my $mshListFilename="$outdir/mshList.txt";
  open(my $mshListFh,">",$mshListFilename) or die "ERROR: could not write to $mshListFilename: $!";
  for(@$mshList){
    print $mshListFh $_."\n";
    push(@genomeName,_truncateFilename($_,$settings));
  }
  close $mshListFh;

  # Instatiate the database and create the table before the threads get to it
  my $mashtreeDbFilename="$outdir/distances.sqlite";
  my $mashtreeDb=Mashtree::Db->new($mashtreeDbFilename);

  # Make an array of distance files for each thread.
  # Because distance files take about the same amount
  # of time to analyze, there is no need to sort.
  my @threadArr=();
  for(my $i=0; $i<@$mshList; $i++){
    my $threadIndex = $i % $$settings{numcpus};
    push(@{ $threadArr[$threadIndex] }, $$mshList[$i]);
  }

  # Initialize the threads
  my @thr;
  for(0..$$settings{numthreads}-1){
    $thr[$_]=threads->new(\&mashDist,$outdir,$threadArr[$_],$mshListFilename,$mashtreeDbFilename,$settings);
  }

  for(@thr){
    logmsg "Waiting to join thread TID".$_->tid;
    my $distfiles=$_->join;
    logmsg "Joined TID".$_->tid;
  }

  return $mashtreeDbFilename;
}

# Individual mash distance
sub mashDist{
  my($outdir,$mshArr,$mshList,$mashtreeDbFilename,$settings)=@_;

  # One distance file for all queries in this thread
  my($distFileFh,$distFile)=tempfile("mashdistXXXXXX", SUFFIX=>".tsv", DIR=>$outdir);

  my $numQueries=0;
  my $mashtreeDb=Mashtree::Db->new($mashtreeDbFilename);
  for my $msh(@$mshArr){
    #my $outfile="$outdir/".basename($msh).".tsv";
    logmsg "Distances for $msh";
    system("mash dist -t $msh -l $mshList >> $distFile");
    die "ERROR with 'mash dist -t $msh -l $mshList'" if $?;
    $numQueries++;
  }

  # If there is anything to add to the database, lock
  # the database.  Only lock it once per thread, optimally.
  if($numQueries > 0){
    lock($dbhLock);
    $mashtreeDb->addDistances($distFile);
  }

  # I think that the thread disconnects the db when
  # this sub ends but I wanted to do it directly and
  # in a readable fashion.
  $mashtreeDb->disconnect();
  close($distFileFh);
  unlink($distFile);
}

sub determineMinimumDepth{
  my($fastq,$mindepth,$kmerlength,$settings)=@_;

  $delta{$fastq}//=10;
  my $defaultDepth=2; # if no valley is detected # TODO should it be five?

  return $mindepth if($mindepth > 0);

  my $basename=basename($fastq,@fastqExt);
  
  # Run the min abundance finder to find the valleys
  my $minAbundanceTempdir="$$settings{tempdir}/$basename.minAbundance.tmp";
  mkdir $minAbundanceTempdir;
  my $minAbundanceCommand="min_abundance_finder.pl --numcpus $$settings{cpus_per_mash} $fastq --kmer $kmerlength --tempdir $minAbundanceTempdir --delta $delta{$fastq}";
  lock($abundanceFinderLock); logmsg "DEBUG: running single mode for $fastq";
  my @valleyLines=`$minAbundanceCommand`;
  # If there is an error, just try running one at a time.
  # I am not sure why there is a seg fault sometimes when
  # more than one are running at the same time though.
  #if($?){
  #  lock($abundanceFinderLock);
  #  @valleyLines=`$minAbundanceCommand`;
  #}
  die "ERROR with min_abundance_finder.pl on $fastq: $!" if($?);
  chomp(@valleyLines);
  # Some cleanup of large files
  unlink $_ for(glob("$minAbundanceTempdir/*"));
  rmdir $minAbundanceTempdir;

  # If there is no valley, return a default value
  #if(!defined $valleyLines[1] || !looks_like_number($valley[1]) || @valley < 1){
  if(!defined $valleyLines[1] || @valleyLines < 1){
    $delta{$fastq}=int($delta{$fastq}/2);
    if($delta{$fastq} > 10){
      logmsg "Trying again to determine a min depth with delta==$delta{$fastq} on $fastq";
      return determineMinimumDepth($fastq,$mindepth,$kmerlength,$settings);
    }
    logmsg "WARNING: no valleys were found! Reporting minimum kmer coverage as $defaultDepth.";
    return $defaultDepth;
  }
  
  # Discard the header but keep the first line
  my($minKmerCount, $countOfCounts)=split(/\t/,$valleyLines[1]);
  # force an "empty" value to zero
  if(!defined($minKmerCount) || !looks_like_number($minKmerCount)){
    $minKmerCount=0;
  }
  # However, the minimum count can't be zero, and so it is one.
  $minKmerCount=1 if($minKmerCount < 1);

  logmsg "Setting the min depth as $minKmerCount for $fastq (delta==$delta{$fastq})";

  return $minKmerCount;
}

sub usage{
  "$0: use distances from Mash (min-hash algorithm) to make a database of distances
  Usage: $0 [options] -o mash.sqlite *.fastq *.fasta *.gbk *.msh
  NOTE: fastq files are read as raw reads;
        fasta, gbk, and embl files are read as assemblies;
        Input files can be gzipped.
  --outfile            ''   Required output sqlite file
  --tempdir            ''   If specified, this directory will not be
                            removed at the end of the script and can
                            be used to cache results for future
                            analyses.
                            If not specified, a dir will be made for you
                            and then deleted at the end of this script.
  --numcpus            1    This script uses Perl threads.
  --version                 Display the version and exit

  TREE OPTIONS
  --truncLength        250  How many characters to keep in a filename
  --sort-order         ABC  For neighbor-joining, the sort order can
                            make a difference. Options include:
                            ABC (alphabetical), random, input-order

  MASH SKETCH OPTIONS
  --genomesize         5000000
  --mindepth           5    If mindepth is zero, then it will be
                            chosen in a smart but slower method,
                            to discard lower-abundance kmers.
  --kmerlength         21
  --sketch-size        10000
  "
}

