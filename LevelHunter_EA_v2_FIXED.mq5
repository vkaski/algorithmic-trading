//+------------------------------------------------------------------+
//|                              LevelHunter_EA_v2_FIXED.mq5         |
//|                      Исправленная стабильная версия               |
//+------------------------------------------------------------------+
#property copyright "LevelHunter EA v2 Fixed"
#property version   "2.02"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>

//--- Параметры
input ENUM_TIMEFRAMES InpStructureTF   = PERIOD_M5;
input ENUM_TIMEFRAMES InpEntryTF       = PERIOD_M1;
input int    InpSwingBars      = 3;
input int    InpLookbackBars   = 200;
input int    InpImpulseBars    = 10;
input double InpZonePoints     = 150.0;
input double InpTouchZone      = 120.0;
input int    InpTypeA_MaxTouch = 2;
input int    InpTypeB_MaxTouch = 3;
input bool   InpTradeBreakout  = true;
input bool   InpUseCandleConfirm = true;
input double InpPinBarRatio    = 0.6;
input double InpEngulfRatio    = 1.1;

input bool   InpUseVolatilityFilter = true;
input double InpMinVolatility  = 30.0;
input double InpMaxVolatility  = 2000.0;
input bool   InpUseTrendFilter = true;
input int    InpTrendMAPeriod  = 20;

input bool   InpUsePartialTP   = true;
input double InpPartial1_Percent = 30.0;
input double InpPartial1_RR    = 1.0;
input double InpPartial2_RR    = 2.5;
input bool   InpUseTrailingStop = true;
input double InpTrailingPercent = 50.0;
input int    InpTradeCooldownMin = 5;

input bool   InpUseDynamicSL   = true;
input int    InpATRPeriod      = 14;
input double InpSLMultiplier   = 1.5;
input double InpRRRatio        = 1.8;
input double InpMinSLPoints    = 200.0;
input double InpMaxSLPoints    = 1500.0;
input double InpFixedSLPoints  = 300.0;
input double InpFixedTPPoints  = 540.0;

input double InpRiskPercent    = 1.0;
input int    InpMaxTrades      = 1;
input double InpMaxDailyLossPercent = 5.0;
input int    InpMagic          = 202408;

input string InpLogFile        = "levellog_v2.csv";
input bool   InpVerboseLog     = true;

//--- Типы
enum LEVEL_TYPE { LEVEL_NONE = 0, LEVEL_TYPE_A = 1, LEVEL_TYPE_B = 2 };
enum LEVEL_DIRECTION { LEVEL_HIGH = 1, LEVEL_LOW = -1 };

//--- Структуры (уменьшенные размеры)
struct PriceLevel
{
    double         price;
    LEVEL_TYPE     ltype;
    LEVEL_DIRECTION direction;
    int            touch_count;
    bool           broken;
    bool           retested;
    datetime       formed_time;
    datetime       last_touch;
    bool           used;
    double         quality_score;
};

struct ActiveTrade
{
    ulong          ticket;
    double         entry_price;
    double         sl;
    double         tp;
    bool           partial_1_closed;
    int            direction;
    datetime       open_time;
    double         initial_sl_pts;
    double         max_profit;
};

//--- Глобальные переменные
CTrade        g_trade;
CPositionInfo g_pos;

PriceLevel    g_levels[100];  // ← ФИКСЕНО: было 500, теперь 100
int           g_level_count = 0;
int           g_atr_handle  = INVALID_HANDLE;
int           g_ma_handle   = INVALID_HANDLE;

ActiveTrade   g_active_trades[10];  // ← ФИКСЕНО: было динамический, теперь 10
int           g_trade_count = 0;

datetime      g_last_trade_time = 0;
int           g_structure_update_bars = 10;
double        g_daily_loss = 0;
datetime      g_daily_loss_date = 0;

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("🔍 [DEBUG] OnInit() запущен");
    
    // Проверка ATR
    g_atr_handle = iATR(_Symbol, InpEntryTF, InpATRPeriod);
    if(g_atr_handle == INVALID_HANDLE)
    {
        Print("❌ [ERROR] Ошибка создания ATR индикатора");
        return INIT_FAILED;
    }
    Print("✅ ATR индикатор создан");

    // Проверка MA
    if(InpUseTrendFilter)
    {
        g_ma_handle = iMA(_Symbol, InpStructureTF, InpTrendMAPeriod, 0, MODE_SMA, PRICE_CLOSE);
        if(g_ma_handle == INVALID_HANDLE)
        {
            Print("❌ [ERROR] Ошибка создания MA индикатора");
            return INIT_FAILED;
        }
        Print("✅ MA индикатор создан");
    }

    // Инициализация CTrade
    g_trade.SetExpertMagicNumber(InpMagic);
    g_trade.SetDeviationInPoints(50);
    g_trade.SetAsyncMode(false);
    Print("✅ CTrade инициализирован");

    // Создание CSV лога
    int fh = FileOpen(InpLogFile, FILE_READ);
    if(fh == INVALID_HANDLE)
    {
        fh = FileOpen(InpLogFile, FILE_WRITE | FILE_CSV | FILE_ANSI);
        if(fh != INVALID_HANDLE)
        {
            FileWrite(fh, "datetime","ticket","symbol","direction",
                      "entry","sl","tp","profit","result","balance","reason");
            FileClose(fh);
            Print("✅ CSV лог создан");
        }
        else
        {
            Print("⚠️ Не удалось создать CSV лог");
        }
    }
    else
    {
        FileClose(fh);
        Print("✅ CSV лог найден");
    }

    // Инициализация массивов
    g_level_count = 0;
    g_trade_count = 0;
    Print("✅ Массивы инициализированы");

    // Первичный поиск уровней
    UpdateLevels();
    Print("✅ UpdateLevels() завершён. Найдено уровней: ", g_level_count);

    Print("═══════════════════════════════════════════");
    Print("✅ LevelHunter EA v2 FIXED запущен");
    Print("═══════════════════════════════════════════");

    return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
    if(g_atr_handle != INVALID_HANDLE) IndicatorRelease(g_atr_handle);
    if(g_ma_handle  != INVALID_HANDLE) IndicatorRelease(g_ma_handle);
    Print("✅ EA завершён");
}

//+------------------------------------------------------------------+
//| GetATRPoints                                                     |
//+------------------------------------------------------------------+
double GetATRPoints()
{
    double atr_buf[];
    ArraySetAsSeries(atr_buf, true);
    if(CopyBuffer(g_atr_handle, 0, 1, 3, atr_buf) < 3)
        return 100.0;
    double pt = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    return atr_buf[1] / pt;
}

//+------------------------------------------------------------------+
//| CheckVolatilityFilter                                            |
//+------------------------------------------------------------------+
bool CheckVolatilityFilter()
{
    if(!InpUseVolatilityFilter) return true;
    double atr_pts = GetATRPoints();
    if(atr_pts < InpMinVolatility || atr_pts > InpMaxVolatility)
        return false;
    return true;
}

//+------------------------------------------------------------------+
//| CheckTrend                                                       |
//+------------------------------------------------------------------+
int CheckTrend()
{
    if(!InpUseTrendFilter) return 0;
    double close_buf[], ma_buf[];
    ArraySetAsSeries(close_buf, true);
    ArraySetAsSeries(ma_buf, true);
    if(CopyClose(_Symbol, InpStructureTF, 0, 3, close_buf) < 3) return 0;
    if(CopyBuffer(g_ma_handle, 0, 0, 3, ma_buf) < 3) return 0;
    if(close_buf[1] > ma_buf[1]) return 1;
    if(close_buf[1] < ma_buf[1]) return -1;
    return 0;
}

//+------------------------------------------------------------------+
//| CalculateLevelQuality (ИСПРАВЛЕНО)                              |
//+------------------------------------------------------------------+
double CalculateLevelQuality(PriceLevel &level)  // ← Принимаем структуру, не индекс
{
    double score = 50.0;
    if(level.ltype == LEVEL_TYPE_A)
        score += 20.0;
    else
        score += 10.0;
    
    if(level.touch_count == 2) score += 15.0;
    if(level.touch_count == 3) score += 10.0;
    if(level.touch_count >= 4) score -= 10.0;
    
    return MathMax(0, MathMin(100, score));
}

//+------------------------------------------------------------------+
//| GetSLTP                                                          |
//+------------------------------------------------------------------+
void GetSLTP(double &sl_pts, double &tp_pts)
{
    if(!InpUseDynamicSL)
    {
        sl_pts = InpFixedSLPoints;
        tp_pts = InpFixedTPPoints;
        return;
    }
    double atr_pts = GetATRPoints();
    sl_pts = atr_pts * InpSLMultiplier;
    sl_pts = MathMax(sl_pts, InpMinSLPoints);
    sl_pts = MathMin(sl_pts, InpMaxSLPoints);
    tp_pts = sl_pts * InpRRRatio;
}

//+------------------------------------------------------------------+
//| CalcLot                                                          |
//+------------------------------------------------------------------+
double CalcLot(double sl_pts)
{
    double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
    double risk_amt = balance * InpRiskPercent / 100.0;
    double tv  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double ts  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
    double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double pv  = tv * (pt / ts);
    if(pv <= 0) return SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double lot      = risk_amt / (sl_pts * pv);
    double min_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double max_lot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double lot_step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
    lot = MathMax(min_lot, MathMin(lot, max_lot));
    return NormalizeDouble(MathRound(lot / lot_step) * lot_step, 2);
}

//+------------------------------------------------------------------+
//| CheckDailyLossLimit                                              |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
    datetime today = (datetime)(TimeCurrent() / 86400 * 86400);
    if(today != g_daily_loss_date)
    {
        g_daily_loss = 0;
        g_daily_loss_date = today;
    }
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    if(g_daily_loss < -(balance * InpMaxDailyLossPercent / 100.0))
        return false;
    return true;
}

//+------------------------------------------------------------------+
//| CheckTradeCooldown                                               |
//+------------------------------------------------------------------+
bool CheckTradeCooldown()
{
    if((TimeCurrent() - g_last_trade_time) < (InpTradeCooldownMin * 60))
        return false;
    return true;
}

//+------------------------------------------------------------------+
//| IsImpulseSwing                                                   |
//+------------------------------------------------------------------+
bool IsImpulseSwing(int swing_bar_idx, LEVEL_DIRECTION dir)
{
    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);
    int need = swing_bar_idx + InpImpulseBars + 5;
    if(CopyHigh(_Symbol, InpStructureTF, 0, need, highs) < need) return false;
    if(CopyLow (_Symbol, InpStructureTF, 0, need, lows)  < need) return false;

    if(dir == LEVEL_HIGH)
    {
        double swing_price = highs[swing_bar_idx];
        for(int i = swing_bar_idx + 1; i < swing_bar_idx + InpImpulseBars + 1; i++)
        {
            if(i >= need) break;
            if(highs[i] > swing_price) return true;
        }
        return false;
    }
    else
    {
        double swing_price = lows[swing_bar_idx];
        for(int i = swing_bar_idx + 1; i < swing_bar_idx + InpImpulseBars + 1; i++)
        {
            if(i >= need) break;
            if(lows[i] < swing_price) return true;
        }
        return false;
    }
}

//+------------------------------------------------------------------+
//| UpdateLevels (ИСПРАВЛЕНО)                                        |
//+------------------------------------------------------------------+
void UpdateLevels()
{
    int bars = InpLookbackBars;
    int sw   = InpSwingBars;
    double highs[], lows[];
    ArraySetAsSeries(highs, true);
    ArraySetAsSeries(lows, true);

    int need = bars + sw + InpImpulseBars + 10;
    if(CopyHigh(_Symbol, InpStructureTF, 0, need, highs) < need) return;
    if(CopyLow (_Symbol, InpStructureTF, 0, need, lows)  < need) return;

    datetime times[];
    ArraySetAsSeries(times, true);
    if(CopyTime(_Symbol, InpStructureTF, 0, need, times) < need) return;

    double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double zone = InpZonePoints * pt;

    PriceLevel temp_levels[100];  // ← Локальный массив
    int temp_count = 0;

    for(int i = sw; i < bars && temp_count < 100; i++)
    {
        // Swing High
        bool is_sh = true;
        for(int j = 1; j <= sw; j++)
            if(highs[i] <= highs[i-j] || highs[i] <= highs[i+j]) { is_sh = false; break; }

        if(is_sh)
        {
            bool dup = false;
            for(int k = 0; k < temp_count; k++)
                if(MathAbs(temp_levels[k].price - highs[i]) < zone) { dup = true; break; }

            if(!dup)
            {
                bool impulse = IsImpulseSwing(i, LEVEL_HIGH);
                temp_levels[temp_count].price       = highs[i];
                temp_levels[temp_count].ltype       = impulse ? LEVEL_TYPE_A : LEVEL_TYPE_B;
                temp_levels[temp_count].direction   = LEVEL_HIGH;
                temp_levels[temp_count].touch_count = 1;
                temp_levels[temp_count].broken      = false;
                temp_levels[temp_count].retested    = false;
                temp_levels[temp_count].formed_time = times[i];
                temp_levels[temp_count].last_touch  = times[i];
                temp_levels[temp_count].used        = false;
                temp_levels[temp_count].quality_score = 0;
                temp_count++;
            }
        }

        // Swing Low
        bool is_sl = true;
        for(int j = 1; j <= sw; j++)
            if(lows[i] >= lows[i-j] || lows[i] >= lows[i+j]) { is_sl = false; break; }

        if(is_sl && temp_count < 100)
        {
            bool dup = false;
            for(int k = 0; k < temp_count; k++)
                if(MathAbs(temp_levels[k].price - lows[i]) < zone) { dup = true; break; }

            if(!dup)
            {
                bool impulse = IsImpulseSwing(i, LEVEL_LOW);
                temp_levels[temp_count].price       = lows[i];
                temp_levels[temp_count].ltype       = impulse ? LEVEL_TYPE_A : LEVEL_TYPE_B;
                temp_levels[temp_count].direction   = LEVEL_LOW;
                temp_levels[temp_count].touch_count = 1;
                temp_levels[temp_count].broken      = false;
                temp_levels[temp_count].retested    = false;
                temp_levels[temp_count].formed_time = times[i];
                temp_levels[temp_count].last_touch  = times[i];
                temp_levels[temp_count].used        = false;
                temp_levels[temp_count].quality_score = 0;
                temp_count++;
            }
        }
    }

    // Перенести данные
    for(int n = 0; n < temp_count; n++)
    {
        for(int o = 0; o < g_level_count; o++)
        {
            if(MathAbs(g_levels[o].price - temp_levels[n].price) < zone)
            {
                temp_levels[n].touch_count = g_levels[o].touch_count;
                temp_levels[n].broken      = g_levels[o].broken;
                temp_levels[n].retested    = g_levels[o].retested;
                temp_levels[n].used        = g_levels[o].used;
                temp_levels[n].last_touch  = g_levels[o].last_touch;
                break;
            }
        }
        // Рассчитать качество ПРАВИЛЬНО
        temp_levels[n].quality_score = CalculateLevelQuality(temp_levels[n]);
    }

    // Скопировать в глобальный массив
    g_level_count = temp_count;
    for(int i = 0; i < g_level_count; i++)
        g_levels[i] = temp_levels[i];
}

//+------------------------------------------------------------------+
//| UpdateTouchesAndBreaks                                           |
//+------------------------------------------------------------------+
void UpdateTouchesAndBreaks()
{
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double touch_dist = InpTouchZone * pt;
    double zone       = InpZonePoints * pt;
    datetime now = TimeCurrent();

    for(int i = 0; i < g_level_count; i++)
    {
        double lvl = g_levels[i].price;
        bool touching = false;
        if(g_levels[i].direction == LEVEL_HIGH)
            touching = (ask >= lvl - touch_dist && ask <= lvl + touch_dist);
        else
            touching = (bid >= lvl - touch_dist && bid <= lvl + touch_dist);

        if(touching && (now - g_levels[i].last_touch) > 60)
        {
            g_levels[i].touch_count++;
            g_levels[i].last_touch = now;
        }

        if(!g_levels[i].broken)
        {
            if(g_levels[i].direction == LEVEL_HIGH && bid > lvl + zone)
                g_levels[i].broken = true;
            else if(g_levels[i].direction == LEVEL_LOW && ask < lvl - zone)
                g_levels[i].broken = true;
        }
        else if(!g_levels[i].retested)
        {
            bool retest = false;
            if(g_levels[i].direction == LEVEL_HIGH)
                retest = (bid >= lvl - touch_dist && bid <= lvl + touch_dist);
            else
                retest = (ask >= lvl - touch_dist && ask <= lvl + touch_dist);
            if(retest) g_levels[i].retested = true;
        }
    }
}

//+------------------------------------------------------------------+
//| IsCandleConfirmed                                                |
//+------------------------------------------------------------------+
bool IsCandleConfirmed(int bar_idx, ENUM_TIMEFRAMES tf, int signal_dir)
{
    if(!InpUseCandleConfirm) return true;
    double o1 = iOpen (_Symbol, tf, bar_idx);
    double h1 = iHigh (_Symbol, tf, bar_idx);
    double l1 = iLow  (_Symbol, tf, bar_idx);
    double c1 = iClose(_Symbol, tf, bar_idx);
    double body  = MathAbs(c1 - o1);
    double range = h1 - l1;
    if(range <= 0) return false;

    if(signal_dir > 0)
    {
        double lower_wick = MathMin(o1, c1) - l1;
        if(body > 0 && lower_wick / body >= InpPinBarRatio && c1 > o1)
            return true;
        double o2 = iOpen (_Symbol, tf, bar_idx + 1);
        double c2 = iClose(_Symbol, tf, bar_idx + 1);
        if(c1 > o1 && c2 < o2 && c1 >= o2 * InpEngulfRatio && o1 <= c2)
            return true;
    }
    else
    {
        double upper_wick = h1 - MathMax(o1, c1);
        if(body > 0 && upper_wick / body >= InpPinBarRatio && c1 < o1)
            return true;
        double o2 = iOpen (_Symbol, tf, bar_idx + 1);
        double c2 = iClose(_Symbol, tf, bar_idx + 1);
        if(c1 < o1 && c2 > o2 && c1 <= o2 * InpEngulfRatio && o1 >= c2)
            return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| FindSignal                                                       |
//+------------------------------------------------------------------+
bool FindSignal(int &signal_dir, double &signal_level, string &reason)
{
    if(!CheckVolatilityFilter()) return false;
    if(!CheckTradeCooldown()) return false;
    if(!CheckDailyLossLimit()) return false;

    int trend = CheckTrend();
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    double touch_dist = InpTouchZone * pt;

    int best_idx = -1;
    double best_quality = 0;

    for(int i = 0; i < g_level_count; i++)
    {
        if(!g_levels[i].broken)
        {
            int max_touch = (g_levels[i].ltype == LEVEL_TYPE_A) ? InpTypeA_MaxTouch : InpTypeB_MaxTouch;
            bool at_level = false;
            int  dir      = 0;

            if(g_levels[i].direction == LEVEL_HIGH &&
               ask >= g_levels[i].price - touch_dist && ask <= g_levels[i].price + touch_dist)
            {
                at_level = true;
                dir = -1;
            }
            else if(g_levels[i].direction == LEVEL_LOW &&
                    bid >= g_levels[i].price - touch_dist && bid <= g_levels[i].price + touch_dist)
            {
                at_level = true;
                dir = 1;
            }

            if(!at_level) continue;
            if(g_levels[i].touch_count < 2) continue;
            if(g_levels[i].touch_count > max_touch) continue;
            if(!IsCandleConfirmed(1, InpEntryTF, dir)) continue;
            if(InpUseTrendFilter && trend != 0 && trend != dir) continue;

            if(g_levels[i].quality_score > best_quality)
            {
                best_quality = g_levels[i].quality_score;
                best_idx = i;
            }
        }

        if(g_levels[i].broken && g_levels[i].retested && InpTradeBreakout && g_levels[i].ltype == LEVEL_TYPE_A)
        {
            int dir = (g_levels[i].direction == LEVEL_HIGH) ? 1 : -1;
            bool at_retest = false;
            if(dir > 0 && ask >= g_levels[i].price - touch_dist && ask <= g_levels[i].price + touch_dist)
                at_retest = true;
            else if(dir < 0 && bid >= g_levels[i].price - touch_dist && bid <= g_levels[i].price + touch_dist)
                at_retest = true;

            if(!at_retest) continue;
            if(!IsCandleConfirmed(1, InpEntryTF, dir)) continue;
            if(InpUseTrendFilter && trend != 0 && trend != dir) continue;

            if(g_levels[i].quality_score > best_quality)
            {
                best_quality = g_levels[i].quality_score;
                best_idx = i;
            }
        }
    }

    if(best_idx < 0) return false;

    signal_dir   = (g_levels[best_idx].direction == LEVEL_HIGH) ? -1 : 1;
    signal_level = g_levels[best_idx].price;
    reason = StringFormat("Q%.0f|%s",
             g_levels[best_idx].quality_score,
             g_levels[best_idx].ltype == LEVEL_TYPE_A ? "A" : "B");

    return true;
}

//+------------------------------------------------------------------+
//| ManageActiveTrades                                               |
//+------------------------------------------------------------------+
void ManageActiveTrades()
{
    if(g_trade_count == 0) return;
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

    for(int i = g_trade_count - 1; i >= 0; i--)
    {
        if(!g_pos.SelectByTicket(g_active_trades[i].ticket)) continue;

        double current_price = (g_active_trades[i].direction > 0) ? bid : ask;
        double profit_pts = (g_active_trades[i].direction > 0) ? 
                           (current_price - g_active_trades[i].entry_price) / pt :
                           (g_active_trades[i].entry_price - current_price) / pt;

        g_active_trades[i].max_profit = MathMax(g_active_trades[i].max_profit, profit_pts);
    }
}

//+------------------------------------------------------------------+
//| CountPositions                                                   |
//+------------------------------------------------------------------+
int CountPositions()
{
    int cnt = 0;
    for(int i = PositionsTotal()-1; i >= 0; i--)
        if(g_pos.SelectByIndex(i))
            if(g_pos.Symbol() == _Symbol && g_pos.Magic() == InpMagic)
                cnt++;
    return cnt;
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
    static datetime last_bar = 0;
    datetime cur_bar = iTime(_Symbol, InpEntryTF, 0);
    if(cur_bar == last_bar) return;
    last_bar = cur_bar;

    static int bar_cnt = 0;
    bar_cnt++;
    if(bar_cnt >= g_structure_update_bars)
    {
        UpdateLevels();
        bar_cnt = 0;
    }

    UpdateTouchesAndBreaks();
    ManageActiveTrades();

    if(CountPositions() >= InpMaxTrades) return;

    int    sig_dir   = 0;
    double sig_level = 0;
    string sig_reason = "";

    if(!FindSignal(sig_dir, sig_level, sig_reason)) return;

    double sl_pts = 0, tp_pts = 0;
    GetSLTP(sl_pts, tp_pts);

    double pt  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
    int    dg  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double lot = CalcLot(sl_pts);

    bool result = false;
    ulong ticket = 0;

    if(sig_dir > 0)
    {
        double sl = NormalizeDouble(ask - sl_pts * pt, dg);
        double tp = NormalizeDouble(ask + tp_pts * pt, dg);
        result = g_trade.Buy(lot, _Symbol, 0, sl, tp, "LH|" + sig_reason);
        if(result) ticket = g_trade.ResultOrder();
    }
    else
    {
        double sl = NormalizeDouble(bid + sl_pts * pt, dg);
        double tp = NormalizeDouble(bid - tp_pts * pt, dg);
        result = g_trade.Sell(lot, _Symbol, 0, sl, tp, "LH|" + sig_reason);
        if(result) ticket = g_trade.ResultOrder();
    }

    if(result)
    {
        g_last_trade_time = TimeCurrent();
        if(g_trade_count < 10 && g_pos.SelectByTicket(ticket))
        {
            g_active_trades[g_trade_count].ticket = ticket;
            g_active_trades[g_trade_count].entry_price = (sig_dir > 0) ? ask : bid;
            g_active_trades[g_trade_count].sl = g_pos.StopLoss();
            g_active_trades[g_trade_count].tp = g_pos.TakeProfit();
            g_active_trades[g_trade_count].direction = sig_dir;
            g_active_trades[g_trade_count].open_time = TimeCurrent();
            g_active_trades[g_trade_count].initial_sl_pts = sl_pts;
            g_active_trades[g_trade_count].max_profit = 0;
            g_active_trades[g_trade_count].partial_1_closed = false;
            g_trade_count++;

            Print(StringFormat("✅ %s | Lot=%.2f | SL=%.0f TP=%.0f pts",
                  sig_dir > 0 ? "BUY" : "SELL", lot, sl_pts, tp_pts));
        }
    }
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &req,
                        const MqlTradeResult  &res)
{
    if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
}

//+------------------------------------------------------------------+
