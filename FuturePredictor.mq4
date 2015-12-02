/**
 * FuturePredictor.mq4
 * Machine Learning EA that predicts the future price action
 * at a specific time of the day based on the past.
 *
 * Copyright 2015, Madyan Al-Jazaeri
 */

#property strict
#property copyright   "Copyright 2015, Madyan Al-Jazaeri"
#property link        "https://github.com/madyan94"
#property description "Machine Learning EA that predicts the future price action."

#define _FP_MAGIC 20151115

extern int StartHour = 9;
extern int EndHour   = 19;

extern int PatternBars     = 8;
extern int MinPatternMatch = 15;
extern int MaxPatternMatch = 30;
extern int PredictionBars  = 4;
extern int MinPatternSim   = 60;
extern int MinBarSim       = 40;

extern int    MinRiskRatio   = 2;
extern double RiskPercentage = 0.05;

extern int Slippage = 20;

int initBar = 0;

int init() {
    return 0;
}

int deinit() {
    return 0;
}

int start() {
    if (OrdersTotal() == 0 && isTradeTime(StartHour, EndHour)) {
        trade();
    }

    return 0;
}

// =========================
// New Orders Functions
// =========================

void trade() {
    double predictedHighest, predictedLowest;
    getPredictions(predictedHighest, predictedLowest);

    int type = chooseType(predictedHighest, predictedLowest);
    double tp = OP_BUY ? predictedHighest : predictedLowest;
    double sl = OP_BUY ? predictedLowest  : predictedHighest;

    if (isRisky(type, sl, tp, MinRiskRatio)) return;

    double volume = calculateVolume(type, sl, RiskPercentage);
    double price  = OP_BUY ? Ask : Bid;

    ObjectCreate("predictedHighest" + string(Time[initBar]), OBJ_TREND, 0, Time[1], predictedHighest, Time[initBar], predictedHighest);
    ObjectCreate("predictedLowest"  + string(Time[initBar]), OBJ_TREND, 0, Time[1], predictedLowest,  Time[initBar], predictedLowest);
    ObjectSetInteger(0, "predictedHighest" + string(Time[initBar]), OBJPROP_COLOR,     clrBlack);
    ObjectSetInteger(0, "predictedHighest" + string(Time[initBar]), OBJPROP_RAY_RIGHT, false);
    ObjectSetInteger(0, "predictedLowest"  + string(Time[initBar]), OBJPROP_COLOR,     clrBlack);
    ObjectSetInteger(0, "predictedLowest"  + string(Time[initBar]), OBJPROP_RAY_RIGHT, false);

    Print("### OrderSend: ", Symbol(), type, volume, price, Slippage, sl, tp, _FP_MAGIC);
    int success = OrderSend(Symbol(), type, volume, price, Slippage, sl, tp, NULL, _FP_MAGIC);
}

bool isTradeTime(int startHour, int endHour) {
    static datetime barTime;

    if (Hour() < startHour || Hour() >= endHour) {
        return false;
    }

    if (barTime == Time[0]) {
        return false;
    }

    barTime = Time[0];
    return true;
}

int chooseType(double high, double low) {
    return (high - Ask > Ask - low) ? OP_BUY : OP_SELL;
}

bool isRisky(int type, double sl, double tp, int minRiskRatio = 2) {
    return (
        (type == OP_BUY  && (tp - Ask) / (Ask - sl) < minRiskRatio) ||
        (type == OP_SELL && (Bid - tp) / (sl - Bid) < minRiskRatio)
    );
}

double calculateVolume(int type, double sl, double riskPercentage = 0.05) {
    double risk = riskPercentage * AccountBalance();
    Print("Risking $" + string(risk));

    double slPoints = type == OP_BUY ? (Ask - sl) / MarketInfo(Symbol(), MODE_TICKSIZE) : (sl - Bid) / MarketInfo(Symbol(), MODE_TICKSIZE);
    Print("slPoints = " + string(slPoints));
    
    return risk / (MarketInfo(Symbol(), MODE_TICKVALUE) * slPoints); // lots
}

// =========================
// Machine Learning Functions
// =========================

void getPredictions(double& predictedHighest, double& predictedLowest) {
    double totalDiffInHighest = 0;
    double totalDiffInLowest  = 0;
    int patternMatch = 0;

    int dayBars = 1440 / Period(); // 24 * 60 = 1440
    int i = dayBars + initBar;
    while (patternMatch < MaxPatternMatch && i < Bars - (PatternBars + initBar - 1) - 5) {
        for (int j = i - 2; j <= i + 2; j++) {
            if (comparePattern(j, PatternBars, MinBarSim, initBar) > MinPatternSim) {
                totalDiffInHighest += predictDiffInHighest(j, PredictionBars);
                totalDiffInLowest  += predictDiffInLowest (j, PredictionBars);
                patternMatch++;
            }
        }

        i += dayBars;
    }

    if (patternMatch < MinPatternMatch) return;

    predictedHighest = High[1 + initBar] + (totalDiffInHighest / patternMatch); // high + average point change
    predictedLowest  = Low [1 + initBar] + (totalDiffInLowest  / patternMatch); // low  + average point change
}

int comparePattern(int endBar, int patternBars = 8, int minBarSim = 60, int shift = 0) {
    int total = 0;

    ObjectsDeleteAll(0, "barSim[");
    for (int i = patternBars; i > 0; i--) {
        int barSim = compareBars(i + shift, endBar + i);

        ObjectCreate("barSim[" + string(endBar + i) + "]", OBJ_TEXT, 0, Time[endBar + i], High[endBar + i] + 0.00075);
        ObjectSetText("barSim[" + string(endBar + i) + "]", string(barSim), 10, "Arial Black", clrBlue);

        if (barSim < minBarSim) {
            return -1;
        }
        total += barSim;
    }

    return (total / patternBars); // average
}

int compareBars(int a, int b) {
    int total;

    // polarity
    bool aIsBullish = Close[a] - Open[a] > 0;
    bool bIsBullish = Close[b] - Open[b] > 0;
    total += (aIsBullish && bIsBullish) || (!aIsBullish && !bIsBullish) ? 100 : 0;

    // bar length
    double aLength = High[a] - Low[a];
    aLength = aLength == 0 ? 0.00001 : aLength;
    double bLength = High[b] - Low[b];
    bLength = bLength == 0 ? 0.00001 : bLength;
    total += calculateSimilarity(aLength, bLength);

    // upper shadow
    double aUpperShadow = (High[a] - (aIsBullish ? Close[a] : Open[a])) / aLength;
    double bUpperShadow = (High[b] - (bIsBullish ? Close[b] : Open[b])) / bLength;
    total += calculateSimilarity(aUpperShadow, bUpperShadow);

    // lower shadow
    double aLowerShadow = ((aIsBullish ? Open[a] : Close[a]) - Low[a]) / aLength;
    double bLowerShadow = ((bIsBullish ? Open[b] : Close[b]) - Low[b]) / bLength;
    total += calculateSimilarity(aLowerShadow, bLowerShadow);

    // body
    double aBody = MathAbs(Open[a] - Close[a]) / aLength;
    double bBody = MathAbs(Open[b] - Close[b]) / bLength;
    total += calculateSimilarity(aBody, bBody);

    // % diff from prev High
    double aPrevLength = High[a + 1] - Low[a + 1];
    aPrevLength = aPrevLength == 0 ? 0.00001 : aPrevLength;
    double bPrevLength = High[b + 1] - Low[b + 1];
    bPrevLength = bPrevLength == 0 ? 0.00001 : bPrevLength;
    double aDiffInHigh = (High[a] - High[a + 1]) / aPrevLength;
    double bDiffInHigh = (High[b] - High[b + 1]) / bPrevLength;
    total += (aDiffInHigh > 0 && bDiffInHigh < 0) || (aDiffInHigh < 0 && bDiffInHigh > 0) ? 0 : calculateSimilarity(MathAbs(aDiffInHigh), MathAbs(bDiffInHigh));

    // % diff from prev Low
    double aDiffInLow = (Low[a] - Low[a + 1]) / aPrevLength;
    double bDiffInLow = (Low[b] - Low[b + 1]) / bPrevLength;
    total += (aDiffInLow > 0 && bDiffInLow < 0) || (aDiffInLow < 0 && bDiffInLow > 0) ? 0 : calculateSimilarity(MathAbs(aDiffInLow), MathAbs(bDiffInLow));

    // Future ideas:
    // atr
    // stochastics
    // macd
    // ma
    // other indicators

    return total / 7; // average
}

int calculateSimilarity(double a, double b) {
    double larger  = a > b ? a : b;
    double smaller = a > b ? b : a;
    return (int) ((1 - (larger - smaller)) * 100);
}

double predictDiffInHighest(int pastBar, int predictionBars = 4) {
    int highest = iHighest(Symbol(), 0, MODE_HIGH, predictionBars, pastBar - (predictionBars - 1));
    return High[highest] - High[pastBar + 1];
}

double predictDiffInLowest(int pastBar, int predictionBars = 4) {
    int lowest = iLowest(Symbol(), 0, MODE_LOW, predictionBars, pastBar - (predictionBars - 1));
    return Low[lowest] - Low[pastBar + 1];
}
