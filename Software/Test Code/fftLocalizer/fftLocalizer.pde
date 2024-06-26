import processing.sound.*;
import themidibus.*;;
import java.util.ArrayList;

FFT fft; //Not used, we're using PitchDetector apparently
AudioIn in;
PitchDetector pd;
MidiBus myBus;
Amplitude amp;
int bands = 64;
float bpm = 188;
float x = 0;
float y = 0;
float yOld = 0;
float ampOld = 0;
int midi;
ArrayList<Integer> notes;
int maxLength = 10;
float ampScale = 800;

float ampThreshold = 0.01;
//float[] spectrum = new float[bands];

Note oldNote = null;

SinOsc osc;
Sound s;

int bucketsPerMeasure = 16; //Going to assume we're starting with We Will Rock You and listening for rhythm; have to adjust this (and probably everything) if we try to do something more general
double[] probs = new double[bucketsPerMeasure];
double[] beatProbs = new double[bucketsPerMeasure]; //P(location | heard a beat)
int[] playMe = new int[bucketsPerMeasure];
int msPerMeasure = 1600; //Probably about 2000??
int msPerBucket = msPerMeasure/bucketsPerMeasure;
double beatThresh = 0.1; //Amplitude threshold to be considered a beat; TODO tune (also adjust down SimpleSynth volume if necessary)

int oldtime; //Processing has 64 bit integers, so we probably don't overflow - max is about 2 billion milliseconds, so about 500 hours
int pitch = 0;
double temponoise = 0.5; //TODO do something better than just noise/2 at +/-1, go see if Processing has a Gaussian table or something

double beatSD = 1; //SD on Gaussians for whether we heard a beat (in #buckets)
double tempoSD = 1; //SD on Gaussians around moving through time (in #buckets)

void setup()
{
  size(1000, 800);
  background(255);
  System.out.println(Sound.list());
  
  Sound s = new Sound(this);
  s.outputDevice(4); //Warning about static method seems fine probably
  
  // Create an Input stream which is routed into the Amplitude analyzer
  //fft = new FFT(this, bands);
  pd = new PitchDetector(this, 0.55); //Last arg is confidence - increase to filter out more garbage
  in = new AudioIn(this, 0);
  amp = new Amplitude(this);

  /*osc = new SinOsc(this);
  osc.freq(440);
  osc.play();*/
  
  myBus = new MidiBus(this, 0, 2);
  MidiBus.list();
  in.amp(1);
  // start the Audio Input
  in.start();
  
  // patch the AudioIn
  //fft.input(in);
  pd.input(in);
  amp.input(in);
  background(255);
  System.out.println("amp threshold is " + ampThreshold);
  notes = new ArrayList<Integer>();
 
 for(int i = 0; i < bucketsPerMeasure; i++){
   probs[i] = 1.0/bucketsPerMeasure;
   playMe[i] = 0;
   beatProbs[i] = 0.01; //We'll normalize this later
 }
 
 //Tell it to play arpeggios
 playMe[0] = 60;
 playMe[bucketsPerMeasure/4] = 64;
 playMe[bucketsPerMeasure/2] = 67;
 playMe[bucketsPerMeasure*3/4] = 72;
 
 for(int i = 0; i < bucketsPerMeasure*3/4; i+=bucketsPerMeasure/4){
   for(int j = 0; j < bucketsPerMeasure; j++){
     int disp = min(abs( (i-j)%bucketsPerMeasure), abs( (j-i)%bucketsPerMeasure));
     //Disp = #buckets off from i that we are
     beatProbs[j] += GaussPDF(disp, 0, beatSD);
   }
   /*beatProbs[i] = 10;
   //Add some probability for being adjacent to a beat when we hear something
   beatProbs[(i+1+bucketsPerMeasure)%bucketsPerMeasure] = 5;
   beatProbs[(i-1+bucketsPerMeasure)%bucketsPerMeasure] = 5;*/
 }
 //Normalize beatProbs
 double beatProbSum = 0;
 for(int i = 0; i < bucketsPerMeasure; i++){
   beatProbSum += beatProbs[i];
 }
 for(int i = 0; i < bucketsPerMeasure; i++){
   beatProbs[i] /= beatProbSum;
   //System.out.println(i);
   //System.out.println(beatProbs[i]);
 }
 //beatProbs should be normalized now
}      

void draw()
{
  oldtime = millis();
  int newtime = oldtime;
  boolean isBeat = false;
  while(newtime%msPerBucket >= oldtime%msPerBucket){
    oldtime = newtime;
    newtime = millis();
    //Wait and listen for high amplitude
    if(amp.analyze() > beatThresh){
      //System.out.println("Beat");
      isBeat = true;
    }
    delay(msPerBucket/10); //Small wait - should get 10 reads per cycle. (Slightly less since code doesn't run instantaneously)
  }
  
  //Compute new probs
  double[] newprobs = new double[bucketsPerMeasure];
  double newprobsum = 0;
  
  for(int i = 0; i < bucketsPerMeasure; i++){
    newprobs[i] = 0;
  }

  for(int i = 0; i < bucketsPerMeasure; i++){
    
    for(int j = 0; j < bucketsPerMeasure; j++){
     int disp = min(abs( (i-j)%bucketsPerMeasure), abs( (j-i)%bucketsPerMeasure));
     //Disp = #buckets off from i that we are
      newprobs[(i+1)%bucketsPerMeasure] += probs[j]*GaussPDF(disp, 0, tempoSD);
   }
   
    
    //Move forward one bucket and add noise
    newprobs[i] = temponoise/2*probs[(i-2+bucketsPerMeasure)%bucketsPerMeasure] + (1-temponoise)*probs[(i-1+bucketsPerMeasure)%bucketsPerMeasure] + (temponoise/2)*probs[(i-0+bucketsPerMeasure)%bucketsPerMeasure];
    //Update based on hearing beats or not (Bayes)
    if(isBeat){
      newprobs[i] *= beatProbs[i];
    }
    else{
      newprobs[i] *= (1-beatProbs[i]);
    }
    newprobsum += newprobs[i];
  }
  //Normalize new probs and get most likely
  double newprobmax = 0.2;
  int newprobmaxind = -1;
  for(int i = 0; i < bucketsPerMeasure; i++){
    newprobs[i] /= newprobsum;
    if(newprobs[i] > newprobmax){
      newprobmax = newprobs[i];
      newprobmaxind = i;
    }
  }
  //Use newprobs as the new probs
  probs = newprobs;
  dispProbArray(probs);
  
  if(newprobmaxind > -1){ //Throw out cases where we're super non-confident about where we are
    int newpitch = playMe[newprobmaxind];
    if(newpitch > 0){ //So we stop each note when the next note starts
      if(pitch > 0){
        myBus.sendNoteOff(new Note(0, pitch, 100));
      }
      //Start new note
      pitch = newpitch; //Which we know is non-zero because of outer if statement
      myBus.sendNoteOn(new Note(0, pitch, 100));

    }
  }
  else{
    System.out.println("Help I'm lost");
  }
  
  System.out.println(newtime);
  System.out.println(oldtime);
  
  System.out.println(isBeat);
}

int MIDIfromPitch(double freq){
  if(freq <= 10){
    return 0;
  }
  
  double logfreq = Math.log(freq);
  double log12thrt2 = Math.log(Math.pow(2, 1.0/12));
  int freqA = 440;
  double logfreqA = Math.log(freqA);
  int midiA = 69;
  
  //Factors of 12thrt2 turn into multiples of log12thrt2 in log space
  //logfreq of 0 corresponds to freq of 1 (e^0 = 1)
  int midi = (int) Math.round(logfreq/log12thrt2 - logfreqA/log12thrt2 + midiA);
  
  //assert(midi == MIDIfromPitch(freq));
  return midi;
}

double pitchFromMIDI(int midi){
  if(midi <= 0){
    return 0;
  }
  
  // midi = logfreq/log12thrt2 - logfreqA/log12thrt2 + midiA
  //logfreq = (midi - midiA + logfreqA/log12thrt2)*log12thrt2
  
  double log12thrt2 = Math.log(Math.pow(2, 1.0/12));
  int freqA = 440;
  double logfreqA = Math.log(freqA);
  int midiA = 69;
  
  double logfreq = (midi - midiA + logfreqA/log12thrt2)*log12thrt2;
  double freq = Math.exp(logfreq);
  
  return freq;
}


void dispProbArray(double[] A){
  background(255);
  int n = A.length;
  for(int i = 0; i < n; i++){
    //stroke(255, 0, 0);
    line((float) (i*width/n), (float) (height), (float) ((i+1)*width/n - 1), (float) (height-A[i]*height));
    fill(0);
    rect(i*width/n, (1- (float)A[i])*height, width/n, (float) A[i]*height); //Works
    //rect((float) (i*width/n), (float) (height), (float) width/n, (float) A[i]*height);
  }
}

double GaussPDF(double x, double mu, double sigma){
  float pi = 3.1415926; //But no one cares since it just shows up as a constant normalization factor anyway
  //mu = mean, sigma = st. dev.
  return 1.0/(sigma*sqrt(pi*2))*exp( (float) (-0.5*((x-mu)/sigma)*((x-mu)/sigma)));
}
