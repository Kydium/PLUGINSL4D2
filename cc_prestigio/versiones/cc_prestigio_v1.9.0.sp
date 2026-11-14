#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PL_VERSION "1.9.0"

// ---- Stats de la ronda (por cliente; solo acciones de SUPERVIVIENTE) ----
int   g_iSIDano[MAXPLAYERS+1];   // dano a especiales
int   g_iKills[MAXPLAYERS+1];    // kills de especiales
int   g_iComunes[MAXPLAYERS+1];  // kills de comunes
int   g_iFF[MAXPLAYERS+1];       // fuego amigo: cuenta 1 por incidente (rafaga agrupada)
float g_fLastFF[MAXPLAYERS+1];   // momento del ultimo FF contado (para agrupar rafagas)
float g_fTankDmg[MAXPLAYERS+1];  // dano acumulado al tank actual (se resetea al morir el tank)
float g_fTankDmgOtros;           // dano al tank no atribuible a un superviviente (fuego, desconectados, etc)
int   g_iTankInfl[MAXPLAYERS+1];     // inflictor del golpe actual (diagnostico de "otros")
int   g_iTankAtkRaw[MAXPLAYERS+1];   // atacante crudo del golpe actual
int   g_iTankDmgType[MAXPLAYERS+1];  // tipo de dano del golpe actual
int   g_iWitchInfl;                  // inflictor del golpe actual a la witch (diagnostico)
int   g_iWitchAtkRaw;                // atacante crudo del golpe actual a la witch
int   g_iWitchDmgType;               // tipo de dano del golpe actual a la witch
float g_fWitchDmgOtros;          // idem para la witch
float g_fWitchDmg[MAXPLAYERS+1]; // dano acumulado a la witch actual (se resetea al morir la witch)
int   g_iHpTankAntes[MAXPLAYERS+1]; // vida del tank antes del golpe (para contar dano exacto)
int   g_iHpSIAntes[MAXPLAYERS+1];   // vida del especial antes del golpe (para contar dano exacto)
int   g_iAtkSI[MAXPLAYERS+1];       // atacante del golpe actual al especial
int   g_iAtkTank[MAXPLAYERS+1];     // atacante del golpe actual al tank
int   g_iHpWitchAntes;              // vida de la witch antes del golpe actual
int   g_iAtkWitch;                  // atacante del golpe actual a la witch
int   g_iWitchEnt;                  // entidad de la witch del golpe actual
int   g_iTankActual;                // userid del tank al que se le esta acumulando dano
bool  g_bTankMostrado;              // ya se mostro el desglose de este tank (evita duplicados)
bool  g_bWitchMostrada;             // ya se mostro el desglose de esta witch (evita duplicados)
char  g_sTankName[MAX_NAME_LENGTH]; // nombre del tank que murio (para el desglose diferido)
char  g_sWitchKiller[96];           // quien mato a la witch (para el desglose diferido)
bool  g_bWitchCorona;               // si la witch murio de un solo tiro
int   g_iTankHpMax;                 // vida mas alta vista del tank actual (para cerrar exacto)
int   g_iTankUltimo;                // ultimo que golpeo al tank (donde se recorta el sobrante)
int   g_iWitchHpMax;                // vida mas alta vista de la witch actual
int   g_iWitchUltimo;               // ultimo que golpeo a la witch

// ---- Skills detectadas por este mismo plugin (autonomo, sin dependencias) ----
float g_fSpawnTime[MAXPLAYERS+1];   // cuando aparecio el especial (para el kill rapido)
int   g_iRockDmg[2049];              // dano acumulado que los supervivientes le hicieron a la roca (TraceAttack, igual que ZoneMod)
int   g_iRockAtk[2049];              // ultimo superviviente que le pego a la roca
bool  g_bRockTocada[2049];           // la roca toco algo (pared, suelo, superviviente): ya no puede ser skeet
float g_fRockComidaT;                // ultimo momento en que una roca le pego a un superviviente (evento player_hurt)
float g_fPinStart[MAXPLAYERS+1];     // cuando un superviviente fue agarrado (para la salvada rapida)
int   g_iPinAtacante[MAXPLAYERS+1];  // que infectado lo tiene agarrado (para mostrar "del charger de X")
int   g_iSmokerTongue[MAXPLAYERS+1]; // estado lengua del smoker: 0=nada, 1=en vuelo, 2=agarro a alguien
float g_fTongueFired[MAXPLAYERS+1];  // cuando el smoker disparo la lengua (para el corte en vuelo)

bool   g_bRoundAwarded = false;

// ---- ConVars ----
ConVar g_cvActivo;
ConVar g_cvFFMin;
ConVar g_cvAnuncio;
ConVar g_cvAuto;
ConVar g_cvTank;
ConVar g_cvWitch;
ConVar g_cvFFVentana;
ConVar g_cvBots;
ConVar g_cvSkeet;
ConVar g_cvDebug;
ConVar g_cvOtrosMin;      // dano minimo para mostrar la linea "otros"
ConVar g_cvWitchHealth;   // cvar del juego: vida de la witch
ConVar g_cvTankHealth;    // cvar del juego: vida del tank
ConVar g_cvRapido;
ConVar g_cvRapidoSeg;
ConVar g_cvSalvada;
ConVar g_cvSalvadaSeg;


// ============================ SKILLS (basado en l4d2_skill_detect de ZoneMod, sin dependencias) ============================
#define SK_ZC_SMOKER   1
#define SK_ZC_BOOMER   2
#define SK_ZC_HUNTER   3
#define SK_ZC_JOCKEY   5
#define SK_ZC_CHARGER  6
#define SK_ZC_TANK     8
#define SK_HITGROUP_HEAD 1

#define SK_SHOTGUN_BLAST   0.1    // pellets dentro de este tiempo = misma escopetazo
#define SK_SHOVE_TIME      0.05   // un empujon cuenta una sola vez dentro de este tiempo
#define SK_VOMIT_TIME      2.25   // duracion del vomito del boomer: cuando contar a cuantos pego
#define SK_WITCH_CHECK     0.1    // espera antes de evaluar el crown
#define SK_MAX_CHARGE_TIME 12.0
#define SK_CHARGE_CHECK    0.25
#define SK_CHARGE_END      2.5
#define SK_CHARGE_RECHECK  3.0
#define SK_DC_TRIGGER_DMG  300
#define SK_DC_FALL_DMG     175
#define SK_DC_RECHECK_DMG  100
#define SK_HOP_CHECK       0.1
#define SK_HOPEND_CHECK    0.1
#define SK_HOP_ACCEL       0.01
#define SK_CARALARM_TIME   0.11

#define SK_VF_CARRIED   (1 << 0)
#define SK_VF_FALL      (1 << 1)
#define SK_VF_DROWN     (1 << 2)
#define SK_VF_HURTLOTS  (1 << 3)
#define SK_VF_AIRDEATH  (1 << 5)
#define SK_VF_OTHERKILL (1 << 6)

#define SK_CA_UNKNOWN   0
#define SK_CA_HIT       1
#define SK_CA_TOUCHED   2
#define SK_CA_EXPLOSION 3
#define SK_CA_BOOMER    4

// un cvar de activacion por cada skill
enum
{
    SK_SKEET, SK_HURTSKEET, SK_LEVEL, SK_HURTLEVEL, SK_DEADSTOP, SK_POP, SK_CROWN, SK_DRAWCROWN,
    SK_ROCKEATEN, SK_SHOVE, SK_HUNTERDP, SK_JOCKEYDP, SK_DEATHCHARGE, SK_BHOP, SK_CARALARM, SK_VOMIT,
    SK_COUNT
};
ConVar g_cvSk[SK_COUNT];
char   g_sSkNom[SK_COUNT][14] = { "skeet", "hurtskeet", "level", "hurtlevel", "deadstop", "pop", "crown", "drawcrown",
                                  "rockeaten", "shove", "hunterdp", "jockeydp", "deathcharge", "bhop", "caralarm", "vomit" };
char   g_sSkDef[SK_COUNT][2]  = { "1", "0", "1", "1", "1", "1", "1", "1",
                                  "0", "0", "1", "1", "1", "1", "1", "0" };
char   g_sSkDes[SK_COUNT][120] = {
    "skeet de Hunter (escopeta, melee, sniper/magnum a la cabeza, granada, en equipo)",
    "cuando matan a un Hunter en el aire pero NO fue skeet completo (daño parcial)",
    "level de Charger (melee en plena carga)",
    "daño a un Charger en plena carga que lo mata sin ser level completo",
    "deadstop: empujar a un Hunter en pleno salto",
    "boomer explotado antes de vomitar a alguien",
    "crown de Witch (un solo escopetazo, sin asustarla)",
    "draw crown de Witch (asustada, escopetazo final fuerte)",
    "roca del Tank que le pega a un superviviente",
    "empujon a un especial (suele ser mucho spam)",
    "high pounce de Hunter",
    "high pounce de Jockey",
    "death charge de Charger",
    "racha de bunnyhop (solo se lo dice al propio jugador)",
    "alarma de auto activada",
    "vomito de Boomer que pega a varios supervivientes" };
ConVar g_cvHunterDPAlt;   // altura minima del high pounce de hunter
ConVar g_cvJockeyDPAlt;   // altura minima del high pounce de jockey
ConVar g_cvDrawCrownMin;  // daño minimo del ultimo tiro para draw crown
ConVar g_cvDCAlt;         // altura minima del death charge
ConVar g_cvBhopMin;       // racha minima de bunnyhop
ConVar g_cvBhopInit;      // velocidad minima del primer salto
ConVar g_cvBhopCont;      // velocidad a la que se sigue contando aunque no acelere
ConVar g_cvVomitMin;      // minimo de supervivientes vomitados para anunciar
ConVar g_cvPounceInt;     // z_pounce_damage_interrupt
ConVar g_cvChargerHp;     // z_charger_health
ConVar g_cvPounceMin;     // z_pounce_damage_range_min
ConVar g_cvPounceMax;     // z_pounce_damage_range_max
ConVar g_cvPounceDmgMax;  // z_hunter_max_pounce_bonus_damage
int    g_iPounceInterrupt = 150;

// hunter
int   g_iHunterShotDmg[MAXPLAYERS+1][MAXPLAYERS+1];
float g_fHunterShotStart[MAXPLAYERS+1][MAXPLAYERS+1];
int   g_iHunterShotDmgTeam[MAXPLAYERS+1];
int   g_iHunterLastHealth[MAXPLAYERS+1];
int   g_iHunterOverkill[MAXPLAYERS+1];
bool  g_bHunterKilledPouncing[MAXPLAYERS+1];
float g_fHunterTracePouncing[MAXPLAYERS+1];
float g_fPouncePos[MAXPLAYERS+1][3];
int   g_iPounceDamage[MAXPLAYERS+1];
// empujones / boomer
float g_fLastShoveT[MAXPLAYERS+1][MAXPLAYERS+1];
int   g_iBoomerShoved[MAXPLAYERS+1];
bool  g_bBoomerHit[MAXPLAYERS+1];
int   g_iVomitHits[MAXPLAYERS+1];
// bunnyhop
bool  g_bIsHopping[MAXPLAYERS+1];
bool  g_bHopCheck[MAXPLAYERS+1];
int   g_iHops[MAXPLAYERS+1];
float g_fHopTop[MAXPLAYERS+1];
float g_fLastHop[MAXPLAYERS+1][3];
// charger / death charge
int   g_iChargeVictim[MAXPLAYERS+1];
int   g_iVictimCharger[MAXPLAYERS+1];
int   g_iVictimFlags[MAXPLAYERS+1];
int   g_iVictimMapDmg[MAXPLAYERS+1];
float g_fChargeTime[MAXPLAYERS+1];
float g_fChargeVictimPos[MAXPLAYERS+1][3];
// witch crown (por entidad de witch)
int   g_iWCrDmg[2049][MAXPLAYERS+1];   // dano por superviviente (indice 0 = otras fuentes)
int   g_iWCrCrowner[2049];
int   g_iWCrShot[2049];
int   g_iWCrType[2049];
bool  g_bWCrSlash[2049];
bool  g_bWCrStartled[2049];
float g_fWCrShotStart[MAXPLAYERS+1];
// alarmas de auto
float g_fLastCarAlarm;
int   g_iAlarmReason[MAXPLAYERS+1];
int   g_iAlarmBoomer;
int   g_iCarSurv[2049];     // ultimo superviviente que toco/golpeo el auto
int   g_iGlassCar[2049];    // auto al que pertenece cada vidrio
StringMap g_smCars;         // nombre del auto -> entidad

// contadores por jugador (se reinician cada ronda)
enum
{
    ST_SKEET, ST_SKEETHURT, ST_SKEETMELEE, ST_LEVEL, ST_LEVELHURT, ST_POP, ST_CROWN, ST_CROWNHURT,
    ST_SHOVE, ST_DEADSTOP, ST_TONGUECUT, ST_SELFCLEAR, ST_ROCKSKEET, ST_ROCKEAT, ST_CLEAR,
    ST_INCAP, ST_DIED, ST_FFTAKEN, ST_TANKDMG, ST_WITCHDMG, ST_HUNTERDP, ST_JOCKEYDP, ST_DEATHCHARGE,
    ST_COUNT
};
int    g_iSt[MAXPLAYERS+1][ST_COUNT];
float  g_fRockHitT[2049];  // ultimo disparo de un superviviente a cada roca

float g_fSkillAnnT[MAXPLAYERS+1];   // ultimo anuncio de skill sobre este especial (evita repetir con el kill rapido)
bool  g_bCarAnn[2049];               // alarma de este auto ya anunciada
bool  g_bDCAnn[MAXPLAYERS+1];        // death charge de esta victima ya anunciado

public Plugin myinfo =
{
    name        = "ClubCampestre Prestigio",
    author      = "Kydium",
    description = "MVP de superviviente por ronda (SI, CI y LVP fuego amigo con %). Acumula prestigio y lo muestra en el chat.",
    version     = PL_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    CreateConVar("cc_prestigio_version", PL_VERSION, "Version del plugin", FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_cvActivo   = CreateConVar("cc_prestigio_activo",   "1",  "Activa/desactiva el sistema de prestigio.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvFFMin    = CreateConVar("cc_prestigio_ff_min",   "1",  "Minimo de impactos de fuego amigo para marcar al LVP.", FCVAR_NOTIFY, true, 0.0);
    g_cvAnuncio  = CreateConVar("cc_prestigio_anuncio",  "1",  "1 = muestra en el chat el MVP/LVP al terminar la ronda. 0 = no aparece (igual reparte prestigio).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvAuto     = CreateConVar("cc_prestigio_auto",     "1",  "1 = premia automaticamente al terminar cada ronda (solo modo rendimiento).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvTank     = CreateConVar("cc_prestigio_tank",     "1",  "1 = al morir un tank, muestra cuanto dano le hizo cada superviviente y su %.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvWitch    = CreateConVar("cc_prestigio_witch",    "1",  "1 = al morir una witch, muestra cuanto dano le hizo cada superviviente y su %.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvFFVentana = CreateConVar("cc_prestigio_ff_ventana", "0", "Segundos para agrupar el fuego amigo seguido como 1 solo incidente. 0 = cuenta cada bala que impacta.", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvBots     = CreateConVar("cc_prestigio_bots",     "1",  "1 = los bots tambien cuentan en las stats y pueden salir MVP/LVP (no acumulan prestigio, no tienen SteamID).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvSkeet    = CreateConVar("cc_prestigio_skeet",    "1",  "Interruptor general de skills de Hunter/Charger (skeet, hurtskeet, level, hurtlevel, deadstop) y de la roca del Tank. Cada skill tiene ademas su propio cvar cc_prestigio_sk_*.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDebug    = CreateConVar("cc_prestigio_debug",    "0",  "1 = imprime info de diagnostico de la lengua del smoker en el chat (para pruebas).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRapido   = CreateConVar("cc_prestigio_rapido",   "1",  "1 = anuncia cuando un especial es eliminado poco despues de aparecer.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRapidoSeg = CreateConVar("cc_prestigio_rapido_seg", "1.0", "Segundos maximos desde que aparece el especial para considerarlo kill rapido.", FCVAR_NOTIFY, true, 0.2, true, 15.0);
    g_cvSalvada  = CreateConVar("cc_prestigio_salvada",  "1",  "1 = anuncia en cuanto tiempo se libera a un companero de un agarre (Hunter, Smoker, Jockey, Charger).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvSalvadaSeg = CreateConVar("cc_prestigio_salvada_seg", "0.5", "Segundos maximos para que una salvada cuente (si tardan mas, no se anuncia).", FCVAR_NOTIFY, true, 0.2, true, 30.0);

    RegConsoleCmd("sm_rendimiento",       Cmd_Rendimiento, "Muestra el rendimiento de la ronda actual.");
    RegConsoleCmd("sm_rn",                Cmd_Rendimiento, "Muestra el rendimiento de la ronda actual (MVP/LVP en vivo).");
    RegAdminCmd  ("sm_prestigio_iniciar", Cmd_Iniciar,     ADMFLAG_GENERIC, "Dispara el premio manualmente.");
    RegAdminCmd  ("sm_prestigio_reset",   Cmd_Reset,       ADMFLAG_GENERIC, "Reinicia las stats de la ronda.");
    RegServerCmd ("cc_prestigio_iniciar", Cmd_IniciarSrv,  "Dispara el premio/voto (para llamar desde otro plugin/cfg).");
    RegServerCmd ("cc_prestigio_reset",   Cmd_ResetSrv,    "Reinicia las stats de la ronda.");

    HookEvent("player_death",   Event_PlayerDeath);    // kills de especiales
    HookEvent("player_incapacitated", Event_PlayerIncap); // superviviente tumbado (para witch)
    HookEvent("player_spawn",   Event_PlayerSpawn);    // marca cuando aparece un especial (kill rapido)
    HookEvent("tongue_pull_stopped", Event_TongueCleared);  // lengua cortada durante el arrastre (incluye cortes)
    HookEvent("choke_stopped",       Event_TongueCleared);  // lengua cortada durante el choke
    // --- agarres (para la salvada rapida) ---
    HookEvent("tongue_grab",         Event_TongueGrab);     // smoker engancha
    HookEvent("lunge_pounce",        Event_PinStart);       // hunter cae encima
    HookEvent("jockey_ride",         Event_PinStart);       // jockey sube
    HookEvent("charger_pummel_start",Event_PinStart);       // charger machaca
    HookEvent("charger_carry_start", Event_PinStart);       // charger lleva
    HookEvent("pounce_stopped",      Event_PinEnd);         // liberado del hunter
    HookEvent("jockey_ride_end",     Event_PinEnd);         // liberado del jockey
    HookEvent("charger_pummel_end",  Event_PinEnd);         // liberado del charger
    // --- estado de la lengua (para distinguir corte en vuelo vs salvada) ---
    HookEvent("ability_use",         Event_AbilityUse);     // smoker dispara la lengua
    HookEvent("tongue_broke_bent",   Event_TongueEnd);      // lengua se rompe (esquina/LOS)
    HookEvent("tongue_release",      Event_TongueEnd);      // lengua liberada
    HookEvent("infected_death", Event_InfectedDeath);  // kills de comunes
    HookEvent("player_hurt",    Event_RockHurt);       // roca que le pega a un superviviente (no es skeet)
    HookEvent("witch_spawn",    Event_WitchSpawn);     // engancha el dano a la witch
    HookEvent("witch_killed",   Event_WitchKilled);    // desglose de dano a la witch
    HookEvent("round_start",    Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end",      Event_RoundEnd,   EventHookMode_PostNoCopy);

    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i)) { SDKHook(i, SDKHook_OnTakeDamage, Hook_TakeDamage); SDKHook(i, SDKHook_OnTakeDamagePost, Hook_TakeDamagePost); SDKHook(i, SDKHook_TraceAttack, Hook_SkTrace); }

    g_cvOtrosMin = CreateConVar("cc_prestigio_otros_min", "100", "Dano minimo sin dueno (objetos del mapa, comunes) para mostrarlo como linea 'otros'. Si es menor, se suma al ultimo de la lista.", FCVAR_NOTIFY, true, 0.0, true, 5000.0);

    g_cvWitchHealth = FindConVar("witch_health");   // vida real de la witch segun la config del server
    g_cvTankHealth  = FindConVar("z_tank_health");  // vida real del tank segun la config del server

    SkInit();   // cvars y eventos de los skills

    AutoExecConfig(true, "cc_prestigio");
}

public void OnMapStart()
{
    CampMapStart();
    ResetRoundAll();
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bRoundAwarded = false;
    SkRoundStart();
    ResetRoundAll();
    g_iTankActual = 0;   // ronda nueva: recien aca se olvida el tank anterior
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    SkRoundEnd();
    if (g_bRoundAwarded) return;
    g_bRoundAwarded = true;
    if (g_cvActivo.BoolValue)
    {
        CheckTankSurvived();
        CheckWitchSurvived();
    }
    if (g_cvActivo.BoolValue && g_cvAuto.BoolValue)
        AwardBestPerformers();
}

public void OnClientPutInServer(int client)
{
    SDKHook(client, SDKHook_OnTakeDamage, Hook_TakeDamage);   // capta dano (SI y fuego amigo)
    SDKHook(client, SDKHook_OnTakeDamagePost, Hook_TakeDamagePost);   // dano exacto al tank
    SDKHook(client, SDKHook_TraceAttack, Hook_SkTrace);               // hunter en pleno salto (skeet)
}

public void OnClientDisconnect(int client)
{
    ResetRoundClient(client);
}

// ============================ STATS DE LA RONDA ============================

void ResetRoundAll()
{
    for (int i = 0; i <= MaxClients; i++) ResetRoundClient(i);
    g_bTankMostrado = true; g_bWitchMostrada = true;   // se re-habilitan solo con un tank/witch nuevo
    // NO se borra g_iTankActual: si se borrara, el mismo tank pareceria "nuevo" y se reimprimiria
    g_iTankHpMax = 0; g_iTankUltimo = 0; g_fTankDmgOtros = 0.0;
    g_iWitchHpMax = 0; g_iWitchUltimo = 0; g_fWitchDmgOtros = 0.0;
}

void ResetRoundClient(int c)
{
    g_iSIDano[c] = 0; g_iKills[c] = 0; g_iComunes[c] = 0; g_iFF[c] = 0; g_fLastFF[c] = 0.0; g_fTankDmg[c] = 0.0; g_fWitchDmg[c] = 0.0;
    g_iHpSIAntes[c] = 0; g_iAtkSI[c] = 0; g_fSpawnTime[c] = 0.0; g_fPinStart[c] = 0.0; g_iPinAtacante[c] = 0;
    for (int k = 0; k < ST_COUNT; k++) g_iSt[c][k] = 0;
    g_iSmokerTongue[c] = 0; g_fTongueFired[c] = 0.0;
}

// dano a especiales + fuego amigo (via OnTakeDamage, confiable para FF en L4D2)
public Action Hook_TakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_cvActivo.BoolValue) return Plugin_Continue;
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim)) return Plugin_Continue;

    // la witch le pego a un superviviente: ya no puede ser crown
    if (GetClientTeam(victim) == 2 && damage > 0.0 && attacker > MaxClients && IsValidEntity(attacker))
    {
        char wcls[16];
        GetEdictClassname(attacker, wcls, sizeof wcls);
        if (StrEqual(wcls, "witch") && attacker < sizeof(g_bWCrSlash)) g_bWCrSlash[attacker] = true;
    }

    // TANK: registrar SIEMPRE la vida antes del golpe, venga de quien venga.
    // Si el atacante no es un superviviente valido, el delta ira a "otros" (asi la suma cierra exacta).
    if (EsTank(victim))
    {
        g_iHpTankAntes[victim] = GetClientHealth(victim);
        bool atkValido = (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker)
                          && GetClientTeam(attacker) == 2 && (!IsFakeClient(attacker) || g_cvBots.BoolValue));
        int duenoFuego = 0;
        if (!atkValido) duenoFuego = DuenoDelFuego(inflictor);   // molotov: atribuir al que la tiro
        if (!atkValido && duenoFuego > 0) { g_iAtkTank[victim] = duenoFuego; }
        else g_iAtkTank[victim] = atkValido ? attacker : -1;
        g_iTankInfl[victim] = inflictor;      // para diagnosticar el dano "otros"
        g_iTankAtkRaw[victim] = attacker;
        g_iTankDmgType[victim] = damagetype;
        int uid = GetClientUserId(victim);
        if (g_iTankActual != uid)
        {
            g_iTankActual = uid;        // tank nuevo: se le empieza a contar dano
            g_bTankMostrado = false;    // y se puede mostrar su desglose
        }
    }

    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return Plugin_Continue;
    if (IsFakeClient(attacker) && !g_cvBots.BoolValue) return Plugin_Continue;   // bots segun cvar
    if (GetClientTeam(attacker) != 2) return Plugin_Continue;  // atacante superviviente
    // Nota: no se descarta damage<=0 aca. El juego puede aplicar vida igual (fuego/explosivos),
    // y el dano real se mide en el post-hook comparando la vida antes/despues.

    int tv = GetClientTeam(victim);
    if (tv == 3)                                    // dano a infectado
    {
        bool esTank = EsTank(victim);
        if (!esTank)                                // el tank lleva su propio desglose aparte
        {
            // vida antes; el dano exacto (sin overkill) se cuenta en el post-hook
            g_iHpSIAntes[victim] = GetClientHealth(victim);
            g_iAtkSI[victim] = attacker;
        }
    }
    else if (tv == 2 && victim != attacker && damage > 0.0)   // fuego amigo: 1 por incidente
    {
        float now = GetEngineTime();
        if (now - g_fLastFF[attacker] >= g_cvFFVentana.FloatValue)
        {
            g_iFF[attacker] += 1;
            StAdd(victim, ST_FFTAKEN);
            g_fLastFF[attacker] = now;
        }
    }

    return Plugin_Continue;
}

// Post-hook: cuenta el dano EXACTO al tank (vida antes - vida despues del golpe)
public void Hook_TakeDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
    if (victim < 1 || victim > MaxClients) return;

    // --- dano EXACTO a especiales (sin overkill), para el MVP SI ---
    int atSI = g_iAtkSI[victim];
    g_iAtkSI[victim] = 0;
    if (atSI >= 1 && atSI <= MaxClients && IsClientInGame(victim) && IsClientInGame(atSI))
    {
        int despuesSI = GetClientHealth(victim);
        if (despuesSI < 0) despuesSI = 0;   // murio: se le quito toda la vida que le quedaba
        int deltaSI = g_iHpSIAntes[victim] - despuesSI;
        if (deltaSI > 0) g_iSIDano[atSI] += deltaSI;
    }

    int at = g_iAtkTank[victim];
    g_iAtkTank[victim] = 0;   // limpiar siempre, para no arrastrar el atacante de un golpe anterior
    if (at == 0 || at > MaxClients) return;
    if (IsClientInGame(victim) && EsTank(victim))
    {
        if (g_iHpTankAntes[victim] > g_iTankHpMax) g_iTankHpMax = g_iHpTankAntes[victim];
        int despues = GetClientHealth(victim);
        if (despues < 0) despues = 0;   // murio: se le quito toda la vida que le quedaba
        int delta = g_iHpTankAntes[victim] - despues;
        if (delta > 0)
        {
            if (at >= 1 && IsClientInGame(at)) { g_fTankDmg[at] += float(delta); g_iTankUltimo = at; StAdd(at, ST_TANKDMG, delta); }
            else
            {
                g_fTankDmgOtros += float(delta);   // dano real pero sin dueno identificable
                if (g_cvDebug.BoolValue)
                {
                    char icls[48]; icls[0] = '\0';
                    int infl = g_iTankInfl[victim];
                    if (infl > 0 && IsValidEntity(infl)) GetEntityClassname(infl, icls, sizeof icls);
                    PrintToChatAll("\x05[debug]\x01 otros(+%d): atkRaw=%d inflictor=%d(%s) dmgtype=%d",
                        delta, g_iTankAtkRaw[victim], infl, icls, g_iTankDmgType[victim]);
                }
            }
        }
    }
}

// Si la entidad es fuego (inferno de molotov / fire_cracker_blast), devuelve el superviviente que lo creo
int DuenoDelFuego(int infl)
{
    if (infl <= MaxClients || !IsValidEntity(infl)) return 0;
    char cls[48]; GetEntityClassname(infl, cls, sizeof cls);
    if (StrContains(cls, "inferno") == -1 && StrContains(cls, "fire") == -1) return 0;
    if (!HasEntProp(infl, Prop_Send, "m_hOwnerEntity")) return 0;
    int owner = GetEntPropEnt(infl, Prop_Send, "m_hOwnerEntity");
    if (owner >= 1 && owner <= MaxClients && IsClientInGame(owner) && GetClientTeam(owner) == 2
        && (!IsFakeClient(owner) || g_cvBots.BoolValue)) return owner;
    return 0;
}

bool EsTank(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return false;
    if (GetClientTeam(client) != 3) return false;
    return GetEntProp(client, Prop_Send, "m_zombieClass") == 8;   // 8 = Tank en L4D2
}

// True si el arma activa del cliente es de cuerpo a cuerpo (melee)
bool EsGolpeMelee(int client)
{
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return false;
    int wep = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (wep <= 0 || !IsValidEntity(wep)) return false;
    char cls[32]; GetEntityClassname(wep, cls, sizeof cls);
    return StrEqual(cls, "weapon_melee");
}

// Rock skeet (mismo metodo que l4d2_skill_detect de ZoneMod):
//  - TraceAttack: acumula el dano de supervivientes a la roca (las balas NO pasan por OnTakeDamage)
//  - Touch: si la roca toca algo (pared, suelo, superviviente) deja de poder ser skeet
//  - al destruirse, espera 0.34 s y anuncia solo si hubo dano, no toco nada y no le pego a nadie
public void OnEntityCreated(int entity, const char[] classname)
{
    if (entity < 0 || entity >= sizeof(g_iRockDmg)) return;
    if (StrEqual(classname, "tank_rock"))
    {
        g_iRockDmg[entity] = 0;
        g_iRockAtk[entity] = 0;
        g_fRockHitT[entity] = 0.0;
        g_bRockTocada[entity] = false;
        SDKHook(entity, SDKHook_TraceAttack, Hook_RockTrace);
        SDKHook(entity, SDKHook_Touch, Hook_RockTouch);
    }
    else if (StrEqual(classname, "witch"))
    {
        SkWitchReset(entity);
    }
    else if (StrEqual(classname, "prop_car_alarm"))
    {
        SDKHook(entity, SDKHook_OnTakeDamage, Hook_CarDamage);
        SDKHook(entity, SDKHook_Touch, Hook_CarTouch);
        SDKHook(entity, SDKHook_Spawn, Hook_CarSpawn);
    }
    else if (StrEqual(classname, "prop_car_glass"))
    {
        g_iGlassCar[entity] = 0;
        SDKHook(entity, SDKHook_OnTakeDamage, Hook_GlassDamage);
        SDKHook(entity, SDKHook_Touch, Hook_GlassTouch);
        SDKHook(entity, SDKHook_Spawn, Hook_GlassSpawn);
    }
}

public Action Hook_RockTrace(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (victim < 0 || victim >= sizeof(g_iRockDmg)) return Plugin_Continue;
    if (attacker < 1 || attacker > MaxClients || !IsClientInGame(attacker)) return Plugin_Continue;
    if (GetClientTeam(attacker) != 2) return Plugin_Continue;
    if (IsFakeClient(attacker) && !g_cvBots.BoolValue) return Plugin_Continue;

    g_iRockDmg[victim] += RoundToFloor(damage);
    g_iRockAtk[victim] = attacker;
    g_fRockHitT[victim] = GetGameTime();   // cuando fue el ultimo disparo

    if (g_cvDebug.BoolValue)
        PrintToChatAll("[debug] roca %d golpeada por %d (dmg %.0f, total %d)", victim, attacker, damage, g_iRockDmg[victim]);
    return Plugin_Continue;
}

public void Hook_RockTouch(int entity, int other)
{
    if (entity < 0 || entity >= sizeof(g_bRockTocada)) return;
    g_bRockTocada[entity] = true;
    SDKUnhook(entity, SDKHook_Touch, Hook_RockTouch);
}

public void Event_RockHurt(Event event, const char[] name, bool dontBroadcast)
{
    char w[16];
    event.GetString("weapon", w, sizeof w);
    if (StrEqual(w, "tank_rock"))
    {
        g_fRockComidaT = GetGameTime();
        int rv = GetClientOfUserId(event.GetInt("userid"));
        int rt = GetClientOfUserId(event.GetInt("attacker"));
        if (g_cvActivo.BoolValue && SkSurv(rv) && SkInf(rt)) { StAdd(rv, ST_ROCKEAT); SkAnnRockEaten(rt, rv); }
    }
}

public void OnEntityDestroyed(int entity)
{
    if (entity < 0 || entity >= sizeof(g_iRockDmg)) return;
    if (g_iRockDmg[entity] <= 0) return;   // nadie le pego (o no es una roca rastreada)

    DataPack dp = new DataPack();
    dp.WriteCell(entity);
    dp.WriteCell(g_iRockAtk[entity]);
    dp.WriteCell(g_iRockDmg[entity]);
    dp.WriteCell(g_bRockTocada[entity] ? 1 : 0);
    dp.WriteFloat(GetGameTime());
    dp.WriteFloat(GetGameTime() - g_fRockHitT[entity]);   // cuanto paso desde el ultimo disparo hasta que desaparecio
    CreateTimer(0.34, Timer_RockSkeet, dp, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);

    g_iRockDmg[entity] = 0;
    g_iRockAtk[entity] = 0;
    g_fRockHitT[entity] = 0.0;
    g_bRockTocada[entity] = false;
}

public Action Timer_RockSkeet(Handle timer, DataPack dp)
{
    dp.Reset();
    int   rock    = dp.ReadCell();
    int   atk     = dp.ReadCell();
    int   dmg     = dp.ReadCell();
    bool  tocada  = dp.ReadCell() != 0;
    float tDestr  = dp.ReadFloat();
    float edad    = dp.ReadFloat();   // segundos entre el ultimo disparo y la desaparicion de la roca

    // una roca que le pego a alguien durante la espera no es skeet
    bool comida = (g_fRockComidaT >= tDestr - 0.6);

    if (g_cvDebug.BoolValue)
        PrintToChatAll("[debug] roca %d destruida: dmg=%d tocada=%d comida=%d edad=%.2f", rock, dmg, tocada, comida, edad);

    if (!g_cvActivo.BoolValue) return Plugin_Stop;
    if (tocada || comida) return Plugin_Stop;
    // Una roca rota por disparos desaparece al instante. Si pasaron mas de ~0.4 s desde el ultimo
    // disparo, la roca ya habia caido al suelo y se esfumo despues (no es skeet).
    if (edad > 0.4) return Plugin_Stop;
    if (atk < 1 || atk > MaxClients || !IsClientInGame(atk)) return Plugin_Stop;
    StAdd(atk, ST_ROCKSKEET);
    if (!g_cvSkeet.BoolValue) return Plugin_Stop;

    char qn[96]; NombreMostrar(atk, qn, sizeof qn);
    PrintToChatAll("\x04✦ \x03%s\x01 le hizo \x04skeet\x01 a una \x04roca\x01 del Tank", qn);
    return Plugin_Stop;
}

// kills de especiales + desglose del tank
public void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim   = GetClientOfUserId(event.GetInt("userid"));

    SkOnDeath(victim, attacker, event);   // skeets, death charge
    if (SkSurv(victim)) StAdd(victim, ST_DIED);

    // si a un superviviente lo mato la witch -> desglose con la vida que le quedo
    if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && GetClientTeam(victim) == 2)
    {
        WitchTumboSuperviviente(event.GetInt("attackerentid", 0));
        RequestFrame(Frame_WipeTank);   // por si con esta muerte quedo todo el equipo abajo
    }

    // Tank abatido por un superviviente -> muestra el desglose.
    // (si "muere" por cambio de control entre jugadores, el asesino no es superviviente y se ignora)
    if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && EsTank(victim)
        && attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker) && GetClientTeam(attacker) == 2)
    {
        // Si ya se mostro el desglose (wipe: "sobrevivio con X"), no repetirlo aunque el tank
        // muera despues por quemadura/fuego. El guard g_bTankMostrado se respeta.
        GetClientName(victim, g_sTankName, sizeof g_sTankName);
        RequestFrame(Frame_DesgloseTank);   // espera un frame: asi el golpe final ya quedo contado
    }

    if (attacker < 1 || victim < 1) return;
    if (!IsClientInGame(attacker)) return;
    if (IsFakeClient(attacker) && !g_cvBots.BoolValue) return;
    if (!IsClientInGame(victim)) return;
    if (GetClientTeam(attacker) != 2 || GetClientTeam(victim) != 3) return;

    int zc = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (zc != 8) g_iKills[attacker]++;   // el tank no cuenta como baja de especial (va aparte)

    // Smoker: limpia el estado de la lengua al morir (ya no se anuncia el corte en vuelo)
    if (victim >= 1 && victim <= MaxClients) g_iSmokerTongue[victim] = 0;

    // Kill rapido: eliminado poco despues de aparecer
    if (g_cvRapido.BoolValue && g_fSpawnTime[victim] > 0.0 && (GetGameTime() - g_fSkillAnnT[victim]) > 1.5)
    {
        float t = GetGameTime() - g_fSpawnTime[victim];
        if (t > 0.0 && t <= g_cvRapidoSeg.FloatValue)
        {
            char en[16]; NombreEspecial(zc, en, sizeof en);
            char qn[96]; NombreMostrar(attacker, qn, sizeof qn);
            PrintToChatAll("\x04➜ \x03%s\x01 eliminó al \x03%s\x01 en \x05%.2f s", qn, en, t);
        }
    }

    g_fSpawnTime[victim] = 0.0;
}

// Marca cuando aparece un especial, para medir el kill rapido
// Un frame despues del spawn el juego ya asigno la vida real del tank
public void Frame_TankVidaInicial(any userid)
{
    int c = GetClientOfUserId(userid);
    if (c < 1 || c > MaxClients || !IsClientInGame(c) || !EsTank(c)) return;
    int hp0 = GetClientHealth(c);
    if (hp0 > g_iTankHpMax) g_iTankHpMax = hp0;
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
    int c = GetClientOfUserId(event.GetInt("userid"));
    if (c >= 1 && c <= MaxClients && IsClientInGame(c) && GetClientTeam(c) == 3)
    {
        g_fSpawnTime[c] = GetGameTime();
        SkOnSpawn(c);          // reinicia el estado de skills de este especial
        g_fSkillAnnT[c] = 0.0;
        if (EsTank(c))
            RequestFrame(Frame_TankVidaInicial, GetClientUserId(c));   // leer su vida ya asignada
    }
}

// La lengua fue liberada (arrastre o choke): se trata como una salvada del Smoker.
public void Event_TongueCleared(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int rescuer = GetClientOfUserId(event.GetInt("userid", 0));   // quien libero
    int victim  = GetClientOfUserId(event.GetInt("victim", 0));   // el companero agarrado
    int smoker  = GetClientOfUserId(event.GetInt("smoker", 0));
    if (smoker >= 1 && smoker <= MaxClients) g_iSmokerTongue[smoker] = 0;

    if (g_cvDebug.BoolValue)
        PrintToChatAll("\x05[debug]\x01 %s: rescuer=%d victim=%d", name, rescuer, victim);

    AnunciarSalvada(rescuer, victim, "Smoker");
}

// Smoker engancha a alguien: marca el agarre (salvada) y el estado de la lengua
public void Event_TongueGrab(Event event, const char[] name, bool dontBroadcast)
{
    int smoker = GetClientOfUserId(event.GetInt("userid", 0));
    int victim = GetClientOfUserId(event.GetInt("victim", 0));
    if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && GetClientTeam(victim) == 2)
    {
        g_fPinStart[victim] = GetGameTime();
        g_iPinAtacante[victim] = (smoker >= 1 && smoker <= MaxClients) ? smoker : 0;
    }
    if (smoker >= 1 && smoker <= MaxClients) g_iSmokerTongue[smoker] = 2;   // agarro a alguien
}

// Smoker dispara la lengua (aun no agarra a nadie)
public void Event_AbilityUse(Event event, const char[] name, bool dontBroadcast)
{
    char ability[32];
    event.GetString("ability", ability, sizeof ability);
    if (StrEqual(ability, "ability_lunge"))
    {
        int hunter = GetClientOfUserId(event.GetInt("userid", 0));
        if (SkInf(hunter)) SkOnAbilityLunge(hunter);   // desde donde salta el hunter (high pounce)
        return;
    }
    if (!StrEqual(ability, "ability_tongue")) return;
    int smoker = GetClientOfUserId(event.GetInt("userid", 0));
    if (smoker >= 1 && smoker <= MaxClients)
    {
        g_iSmokerTongue[smoker] = 1;              // lengua en vuelo
        g_fTongueFired[smoker] = GetGameTime();
    }
}

// La lengua termino (se rompio o solto) sin que la matemos
public void Event_TongueEnd(Event event, const char[] name, bool dontBroadcast)
{
    int smoker = GetClientOfUserId(event.GetInt("userid", 0));
    if (smoker >= 1 && smoker <= MaxClients) g_iSmokerTongue[smoker] = 0;
}

// Un superviviente fue agarrado: marca el momento (para medir la salvada)
public void Event_PinStart(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("victim", 0));
    int atacante = GetClientOfUserId(event.GetInt("userid", 0));
    if (victim >= 1 && victim <= MaxClients && IsClientInGame(victim) && GetClientTeam(victim) == 2)
    {
        g_fPinStart[victim] = GetGameTime();
        g_iPinAtacante[victim] = (atacante >= 1 && atacante <= MaxClients) ? atacante : 0;
    }
}

// Un superviviente fue liberado de un hunter/jockey/charger: anuncia en cuanto tiempo
public void Event_PinEnd(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("victim", 0));
    int rescuer;
    char tipo[16];

    if (StrEqual(name, "pounce_stopped"))      { rescuer = GetClientOfUserId(event.GetInt("userid", 0));  strcopy(tipo, sizeof tipo, "Hunter"); }
    else if (StrEqual(name, "jockey_ride_end")){ rescuer = GetClientOfUserId(event.GetInt("rescuer", 0)); strcopy(tipo, sizeof tipo, "Jockey"); }
    else                                        { rescuer = GetClientOfUserId(event.GetInt("rescuer", 0)); strcopy(tipo, sizeof tipo, "Charger"); }

    AnunciarSalvada(rescuer, victim, tipo);
}

void AnunciarSalvada(int rescuer, int victim, const char[] tipo)
{
    if (!g_cvActivo.BoolValue || !g_cvSalvada.BoolValue) return;
    if (victim < 1 || victim > MaxClients || !IsClientInGame(victim)) return;
    if (g_fPinStart[victim] <= 0.0) return;

    float t = GetGameTime() - g_fPinStart[victim];
    g_fPinStart[victim] = 0.0;
    if (t <= 0.0) return;
    if (t > g_cvSalvadaSeg.FloatValue) return;   // tardaron mucho -> no cuenta

    char vn[96]; NombreMostrar(victim, vn, sizeof vn);
    if (rescuer >= 1 && rescuer <= MaxClients && IsClientInGame(rescuer) && rescuer != victim
        && (!IsFakeClient(rescuer) || g_cvBots.BoolValue))
    {
        StAdd(rescuer, ST_CLEAR);   // salvada rapida
        char rn[96]; NombreMostrar(rescuer, rn, sizeof rn);
        // dueno del especial: "del charger de X"
        int owner = g_iPinAtacante[victim];
        if (owner >= 1 && owner <= MaxClients) g_fSkillAnnT[owner] = GetGameTime();
        char tipoMin[16]; strcopy(tipoMin, sizeof tipoMin, tipo);
        for (int k = 0; tipoMin[k] != '\0'; k++) tipoMin[k] = CharToLower(tipoMin[k]);
        if (owner >= 1 && owner <= MaxClients && IsClientInGame(owner) && !IsFakeClient(owner))
        {
            char on[96]; NombreMostrar(owner, on, sizeof on);
            PrintToChatAll("\x04✚ \x03%s\x01 liberó al instante a \x03%s\x01 del %s de \x03%s \x01(\x05%.2f segundos\x01)", rn, vn, tipoMin, on, t);
        }
        else
            PrintToChatAll("\x04✚ \x03%s\x01 liberó al instante a \x03%s\x01 del %s \x01(\x05%.2f segundos\x01)", rn, vn, tipoMin, t);
    }
    else
    {
        // contadores: corte con melee o auto-liberado del smoker (solo si se libero a si mismo)
        if (StrEqual(tipo, "Smoker") && rescuer == victim)
            StAdd(victim, EsGolpeMelee(victim) ? ST_TONGUECUT : ST_SELFCLEAR);
        // "corto la lengua" SOLO si fue con melee (un empujon no cuenta)
        if (StrEqual(tipo, "Smoker") && EsGolpeMelee(victim))
        {
            int owner2 = g_iPinAtacante[victim];   // el smoker que lo tenia enganchado
            if (owner2 >= 1 && owner2 <= MaxClients && IsClientInGame(owner2) && !IsFakeClient(owner2))
            {
                char on2[96]; NombreMostrar(owner2, on2, sizeof on2);
                PrintToChatAll("\x04✦ \x03%s\x01 cortó la lengua del smoker de \x03%s", vn, on2);
            }
            else
                PrintToChatAll("\x04✦ \x03%s\x01 cortó la lengua de un \x04smoker", vn);
        }
        // Hunter, Jockey y Charger: no se anuncia el auto-liberado (solo cuenta cuando te libera un companero)
    }
}

// Nombre del especial segun su clase
void NombreEspecial(int zc, char[] out, int maxlen)
{
    switch (zc)
    {
        case 1:  strcopy(out, maxlen, "Smoker");
        case 2:  strcopy(out, maxlen, "Boomer");
        case 3:  strcopy(out, maxlen, "Hunter");
        case 4:  strcopy(out, maxlen, "Spitter");
        case 5:  strcopy(out, maxlen, "Jockey");
        case 6:  strcopy(out, maxlen, "Charger");
        case 8:  strcopy(out, maxlen, "Tank");
        default: strcopy(out, maxlen, "especial");
    }
}

// Imprime el desglose de dano a un jefe (tank/witch): lista ordenada [dano] (%) nombre.
// El % es proporcional a la vida total del jefe = dano total + vida que le quedo (hpRestante).
// Si murio (hpRestante < 0), la base es el dano total (los % suman ~100). Solo imprime si hubo dano.
void ImprimirDesglose(float dmg[MAXPLAYERS+1], const char[] header, int hpRestante, int hpMax, int ultimo, float otros)
{
    // Cerrar exacto: el overkill del golpe final se recorta al ultimo que golpeo.
    // Solo aplica cuando hpMax es coherente (>= dano + vida restante); si no lo es,
    // la vida real se deduce como dano + vida restante y no se recorta nada.
    if (hpMax > 0 && ultimo >= 1 && ultimo <= MaxClients)
    {
        float suma = otros;
        for (int i = 1; i <= MaxClients; i++) suma += dmg[i];
        float tope = float(hpMax) - float(hpRestante > 0 ? hpRestante : 0);
        if (tope > 0.0 && suma > tope)
        {
            float sobra = suma - tope;
            if (sobra > dmg[ultimo]) sobra = dmg[ultimo];   // nunca recortar mas que su propio aporte
            dmg[ultimo] -= sobra;
            if (dmg[ultimo] < 0.0) dmg[ultimo] = 0.0;
        }
    }

    float tot = otros;
    for (int i = 1; i <= MaxClients; i++) tot += dmg[i];

    if (tot <= 0.0)
    {
        for (int i = 1; i <= MaxClients; i++) dmg[i] = 0.0;
        return;
    }

    // Vida total del jefe para el %: preferimos su vida maxima real (hpMax).
    // Si no se pudo leer o es incoherente, se deduce como dano + vida restante.
    float base = tot;
    if (hpRestante > 0) base = tot + float(hpRestante);
    if (hpMax > 0 && float(hpMax) > base) base = float(hpMax);

    int   idx[MAXPLAYERS+1];
    float val[MAXPLAYERS+1];
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i)) continue;
        if (IsFakeClient(i) && !g_cvBots.BoolValue) continue;
        if (dmg[i] <= 0.0) continue;
        idx[n] = i; val[n] = dmg[i]; n++;
    }
    // Dano sin dueno (objetos del mapa, comunes, mundo):
    // si es considerable se muestra como "otros"; si es poco, se suma al ultimo de la lista
    if (otros >= 1.0)
    {
        if (otros >= g_cvOtrosMin.FloatValue || n == 0)
        {
            idx[n] = 0; val[n] = otros; n++;   // idx 0 = "otros"
        }
        else
        {
            int menor = 0;
            for (int i = 1; i < n; i++)
                if (val[i] < val[menor]) menor = i;
            val[menor] += otros;   // ruido minimo: se suma al que menos hizo
        }
    }

    if (n == 0)   // nadie valido que listar: no imprimir nada
    {
        for (int i = 1; i <= MaxClients; i++) dmg[i] = 0.0;
        return;
    }

    for (int a = 0; a < n - 1; a++)
    {
        int mx = a;
        for (int b = a + 1; b < n; b++)            if (val[b] > val[mx]) mx = b;
        if (mx != a)
        {
            float tv = val[a]; val[a] = val[mx]; val[mx] = tv;
            int ti = idx[a]; idx[a] = idx[mx]; idx[mx] = ti;
        }
    }

    if (g_cvDebug.BoolValue)
        PrintToChatAll("\x05[debug]\x01 vidaMax=%d restante=%d danoTotal=%d base=%d", hpMax, hpRestante, RoundToNearest(tot), RoundToNearest(base));

    PrintToChatAll("%s", header);

    // Reparto de redondeo: el total mostrado debe sumar exacto el dano real.
    // Se redondea hacia abajo y las unidades sobrantes se dan a los que tenian mayor fraccion.
    int   ent[MAXPLAYERS+1];
    float frac[MAXPLAYERS+1];
    int sumaEnt = 0;
    for (int i = 0; i < n; i++)
    {
        ent[i]  = RoundToFloor(val[i]);
        frac[i] = val[i] - float(ent[i]);
        sumaEnt += ent[i];
    }
    int faltan = RoundToNearest(tot) - sumaEnt;
    for (int k = 0; k < faltan; k++)
    {
        int mejor = -1;
        for (int i = 0; i < n; i++)
            if (mejor == -1 || frac[i] > frac[mejor]) mejor = i;
        if (mejor == -1) break;
        ent[mejor]++; frac[mejor] = -1.0;
    }

    for (int i = 0; i < n; i++)
    {
        char nm[96];
        if (idx[i] == 0) strcopy(nm, sizeof nm, "otros");
        else NombreMostrar(idx[i], nm, sizeof nm);
        int d = ent[i];
        int pct = RoundToNearest(val[i] * 100.0 / base);
        // el primero se destaca en naranja, el resto en turquesa
        if (i == 0)
            PrintToChatAll("\x01[\x04%d\x01] \x05(%d%%)\x01 \x04%s", d, pct, nm);
        else
            PrintToChatAll("\x01[\x05%d\x01] \x05(%d%%)\x01 \x03%s", d, pct, nm);
    }

    for (int i = 1; i <= MaxClients; i++) dmg[i] = 0.0;
}

// Desglose del tank. hpRestante < 0 = murio; >= 0 = sobrevivio con esa vida.
public void Frame_DesgloseTank(any data)
{
    RequestFrame(Frame_DesgloseTank2);   // 2do frame: asegura que el golpe final ya se conto
}

public void Frame_DesgloseTank2(any data)
{
    DesgloseTank(g_sTankName, -1);   // -1 = murio
}

void DesgloseTank(const char[] tankName, int hpRestante)
{
    if (g_bTankMostrado) return;   // ya se mostro el desglose de este tank
    if (!g_cvTank.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++) g_fTankDmg[i] = 0.0;
        return;
    }
    char header[192];
    if (hpRestante < 0)
        Format(header, sizeof header, "\x04» Daño al Tank \x01(\x03%s\x01)", tankName);
    else
        Format(header, sizeof header, "\x04» El Tank \x01(\x03%s\x01) sobrevivió con \x05%d\x01 de vida", tankName, hpRestante);
    int vidaTank = VidaTank();
    if (g_iTankHpMax > vidaTank) vidaTank = g_iTankHpMax;   // por si tuviera mas vida de la esperada
    ImprimirDesglose(g_fTankDmg, header, hpRestante, vidaTank, g_iTankUltimo, g_fTankDmgOtros);
    g_fTankDmgOtros = 0.0;
    g_bTankMostrado = true;   // no volver a mostrarlo para este tank
    g_iTankHpMax = 0; g_iTankUltimo = 0;
}

// Al terminar la ronda: si quedó un tank vivo, muestra el desglose con su vida restante.
// Al terminar la ronda: si quedó un tank vivo (wipe), muestra el desglose con su vida restante.
void CheckTankSurvived()
{
    if (!g_cvTank.BoolValue) return;
    int t = GetClientOfUserId(g_iTankActual);   // el tank al que se le hizo dano
    if (t >= 1 && t <= MaxClients && IsClientInGame(t) && EsTank(t) && IsPlayerAlive(t))
    {
        char nm[MAX_NAME_LENGTH]; GetClientName(t, nm, sizeof nm);
        DesgloseTank(nm, GetClientHealth(t));
    }
}

// ============================ WITCH ============================

// La witch es una entidad (no un jugador). Se engancha su dano al aparecer.
// Vida total de la witch segun la config del server (witch_health, por defecto 1000)
int VidaWitch()
{
    int v = (g_cvWitchHealth != null) ? g_cvWitchHealth.IntValue : 1000;
    return (v > 0) ? v : 1000;
}

// Vida total del tank segun la config del server (z_tank_health)
int VidaTank()
{
    int v = (g_cvTankHealth != null) ? g_cvTankHealth.IntValue : 0;
    return (v > 0) ? v : 0;
}

// Un frame despues del spawn el juego ya asigno la vida real de la witch
public void Frame_WitchVidaInicial(any ref)
{
    int witch = EntRefToEntIndex(ref);
    if (witch == INVALID_ENT_REFERENCE || !IsValidEntity(witch)) return;
    if (!HasEntProp(witch, Prop_Data, "m_iHealth")) return;
    int hp0 = GetEntProp(witch, Prop_Data, "m_iHealth");
    if (hp0 > g_iWitchHpMax) g_iWitchHpMax = hp0;
}

public void Event_WitchSpawn(Event event, const char[] name, bool dontBroadcast)
{
    for (int i = 1; i <= MaxClients; i++) g_fWitchDmg[i] = 0.0;   // witch nueva, cuenta desde cero
    g_iWitchHpMax = 0; g_iWitchUltimo = 0; g_fWitchDmgOtros = 0.0;
    g_bWitchMostrada = false;   // witch nueva: se puede mostrar su desglose
    int witch = event.GetInt("witchid");
    if (witch > 0 && IsValidEntity(witch))
    {
        RequestFrame(Frame_WitchVidaInicial, EntIndexToEntRef(witch));   // vida real ya asignada
        SDKHook(witch, SDKHook_OnTakeDamage, Hook_WitchDamage);
        SDKHook(witch, SDKHook_OnTakeDamagePost, Hook_WitchDamagePost);
    }
}

public Action Hook_WitchDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (!g_cvActivo.BoolValue) return Plugin_Continue;
    // Registrar SIEMPRE la vida antes del golpe. Si el atacante no es un superviviente
    // valido, el delta ira a "otros" (asi la suma cierra exacta).
    g_iHpWitchAntes = GetEntProp(victim, Prop_Data, "m_iHealth");
    bool atkValido = (attacker >= 1 && attacker <= MaxClients && IsClientInGame(attacker)
                      && GetClientTeam(attacker) == 2 && (!IsFakeClient(attacker) || g_cvBots.BoolValue));
    int duenoFuegoW = atkValido ? 0 : DuenoDelFuego(inflictor);   // molotov: atribuir al que la tiro
    if (!atkValido && duenoFuegoW > 0) g_iAtkWitch = duenoFuegoW;
    else g_iAtkWitch = atkValido ? attacker : -1;
    g_iWitchEnt = victim;
    g_iWitchInfl = inflictor; g_iWitchAtkRaw = attacker; g_iWitchDmgType = damagetype;
    return Plugin_Continue;
}

// Post-hook: cuenta el dano EXACTO a la witch (vida antes - vida despues)
public void Hook_WitchDamagePost(int victim, int attacker, int inflictor, float damage, int damagetype)
{
    SkWitchDamage(victim, attacker, damage, damagetype);   // seguimiento de crown
    // solo procesa si este golpe es el mismo que registro el pre-hook
    if (g_iAtkWitch == 0 || g_iAtkWitch > MaxClients || g_iWitchEnt != victim)
    {
        g_iAtkWitch = 0; g_iWitchEnt = 0;
        return;
    }
    if (g_iHpWitchAntes > g_iWitchHpMax) g_iWitchHpMax = g_iHpWitchAntes;
    int despues = 0;
    if (IsValidEntity(victim) && HasEntProp(victim, Prop_Data, "m_iHealth"))
    {
        despues = GetEntProp(victim, Prop_Data, "m_iHealth");
        if (despues < 0) despues = 0;   // murio: se le quito toda la vida que le quedaba
    }
    int delta = g_iHpWitchAntes - despues;
    if (delta > 0)
    {
        if (g_iAtkWitch >= 1 && IsClientInGame(g_iAtkWitch)) { g_fWitchDmg[g_iAtkWitch] += float(delta); g_iWitchUltimo = g_iAtkWitch; StAdd(g_iAtkWitch, ST_WITCHDMG, delta); }
        else
        {
            g_fWitchDmgOtros += float(delta);   // dano real pero sin dueno identificable
            if (g_cvDebug.BoolValue)
            {
                char icls[48]; icls[0] = '\0';
                if (g_iWitchInfl > 0 && IsValidEntity(g_iWitchInfl)) GetEntityClassname(g_iWitchInfl, icls, sizeof icls);
                PrintToChatAll("\x05[debug]\x01 witch otros(+%d): atkRaw=%d inflictor=%d(%s) dmgtype=%d",
                    delta, g_iWitchAtkRaw, g_iWitchInfl, icls, g_iWitchDmgType);
            }
        }
    }
    g_iAtkWitch = 0; g_iWitchEnt = 0;
}

public void Event_WitchKilled(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++) g_fWitchDmg[i] = 0.0;
        return;
    }
    int killer = GetClientOfUserId(event.GetInt("userid"));
    bool corona = (event.GetBool("oneshot") || event.GetBool("oneshotkill"));
    SkWitchKilled(event.GetInt("witchid"), killer, event.GetBool("oneshot"));
    if (killer >= 1 && killer <= MaxClients && IsClientInGame(killer))
        NombreMostrar(killer, g_sWitchKiller, sizeof g_sWitchKiller);
    else
        g_sWitchKiller[0] = '\0';
    g_bWitchCorona = corona;
    RequestFrame(Frame_DesgloseWitch);   // espera un frame: asi el golpe final ya quedo contado
}

public void Frame_DesgloseWitch(any data)
{
    RequestFrame(Frame_DesgloseWitch2);   // 2do frame: asegura que el golpe final ya se conto
}

public void Frame_DesgloseWitch2(any data)
{
    DesgloseWitch(g_sWitchKiller, -1, g_bWitchCorona);
}

// Desglose de la witch. hpRestante < 0 = murio; >= 0 = sobrevivio con esa vida.
void DesgloseWitch(const char[] quien, int hpRestante, bool corona)
{
    if (g_bWitchMostrada) return;   // ya se mostro el desglose de esta witch
    if (!g_cvWitch.BoolValue)
    {
        for (int i = 1; i <= MaxClients; i++) g_fWitchDmg[i] = 0.0;
        return;
    }
    char header[192];
    if (hpRestante < 0)
    {
        if (quien[0] != '\0')
            Format(header, sizeof header, "\x04» Daño a la Witch \x01(%s\x03%s\x01)", corona ? "coronada por " : "matada por ", quien);
        else
            Format(header, sizeof header, "\x04» Daño a la Witch");
    }
    else
        Format(header, sizeof header, "\x04» La Witch \x01sobrevivió con \x05%d\x01 de vida", hpRestante);
    int vidaTotal = VidaWitch();
    if (g_iWitchHpMax > vidaTotal) vidaTotal = g_iWitchHpMax;   // por si tuviera mas vida de la esperada
    ImprimirDesglose(g_fWitchDmg, header, hpRestante, vidaTotal, g_iWitchUltimo, g_fWitchDmgOtros);
    g_fWitchDmgOtros = 0.0;
    g_bWitchMostrada = true;   // no volver a mostrarla
    g_iWitchHpMax = 0; g_iWitchUltimo = 0;
}

// Al terminar la ronda: si quedó una witch viva, muestra el desglose con su vida restante.
void CheckWitchSurvived()
{
    if (!g_cvWitch.BoolValue) return;
    int witch = FindEntityByClassname(-1, "witch");
    if (witch != -1)
    {
        int hp = GetEntProp(witch, Prop_Data, "m_iHealth");
        if (hp < 0) hp = 0;
        DesgloseWitch("", hp, false);
    }
}

// Si a un superviviente lo tumba/mata la witch, muestra el desglose con la vida que le quedo a la witch
void WitchTumboSuperviviente(int attackerentid)
{
    if (!g_cvActivo.BoolValue || !g_cvWitch.BoolValue) return;
    if (attackerentid <= 0 || attackerentid > 4096 || !IsValidEntity(attackerentid)) return;
    char cls[32]; GetEntityClassname(attackerentid, cls, sizeof cls);
    if (g_cvDebug.BoolValue)
        PrintToChatAll("\x05[debug]\x01 tumbado por ent=%d clase=%s", attackerentid, cls);
    if (!StrEqual(cls, "witch")) return;
    int hp = GetEntProp(attackerentid, Prop_Data, "m_iHealth");
    if (hp < 0) hp = 0;
    DesgloseWitch("", hp, false);
}

public void Event_PlayerIncap(Event event, const char[] name, bool dontBroadcast)
{
    int caido = GetClientOfUserId(event.GetInt("userid"));
    if (SkSurv(caido)) StAdd(caido, ST_INCAP);
    // un superviviente fue tumbado -> revisar si el equipo quedo todo abajo (wipe con tank vivo)
    RequestFrame(Frame_WipeTank);
}

public void Frame_WipeTank(any data)
{
    RevisarWipeTank();
}

// True si queda al menos un superviviente vivo y de pie (no incapacitado ni colgado)
bool HaySupervivienteDePie()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 2) continue;
        if (!IsPlayerAlive(i)) continue;
        if (HasEntProp(i, Prop_Send, "m_isIncapacitated") && GetEntProp(i, Prop_Send, "m_isIncapacitated")) continue;
        if (HasEntProp(i, Prop_Send, "m_isHangingFromLedge") && GetEntProp(i, Prop_Send, "m_isHangingFromLedge")) continue;
        return true;
    }
    return false;
}

// Si todos los supervivientes estan abajo y el tank sigue vivo -> muestra su vida restante
void RevisarWipeTank()
{
    if (!g_cvTank.BoolValue) return;
    if (HaySupervivienteDePie()) return;   // todavia hay alguien de pie
    int t = GetClientOfUserId(g_iTankActual);   // el tank al que se le hizo dano
    if (t >= 1 && t <= MaxClients && IsClientInGame(t) && EsTank(t) && IsPlayerAlive(t))
    {
        char nm[MAX_NAME_LENGTH]; GetClientName(t, nm, sizeof nm);
        DesgloseTank(nm, GetClientHealth(t));
    }
}

// kills de comunes
public void Event_InfectedDeath(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int killer = GetClientOfUserId(event.GetInt("attacker"));
    if (killer >= 1 && killer <= MaxClients && IsClientInGame(killer)
        && (!IsFakeClient(killer) || g_cvBots.BoolValue) && GetClientTeam(killer) == 2)
        g_iComunes[killer]++;
}

// ============================ PREMIO ============================

int Pct(int part, int total)
{
    if (total <= 0) return 0;
    return RoundToNearest(float(part) * 100.0 / float(total));
}

// Un cliente entra en las stats si esta en juego y (es humano con SteamID) o (es bot y el cvar lo permite)
// Envia a un jugador su posicion personal (SI y CI) en privado
void RangoPersonal(int c, int totSI, int totKills, int totCom, int totFF)
{
    if (c < 1 || c > MaxClients || !IsClientInGame(c)) return;
    if (!ContarEnStats(c)) return;
    // sin estadisticas de superviviente en esta ronda (jugo de infectado): no se le muestra nada
    if (g_iSIDano[c] <= 0 && g_iKills[c] <= 0 && g_iComunes[c] <= 0 && g_iFF[c] <= 0) return;

    char buf[192];

    // rango SI (por dano a especiales)
    int rankSI = 1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!ContarEnStats(i) || i == c) continue;
        if (g_iSIDano[i] > g_iSIDano[c]) rankSI++;
    }
    if (rankSI <= 4 && (g_iSIDano[c] > 0 || g_iKills[c] > 0))   // hasta el puesto 4 y con datos propios
    {
        Format(buf, sizeof buf, "\x04Tu rango SI\x01 » \x05#%d\x01 · \x05%d\x01 daño \x05[%d%%]\x01 · \x05%d\x01 bajas \x05[%d%%]",
            rankSI, g_iSIDano[c], Pct(g_iSIDano[c], totSI), g_iKills[c], Pct(g_iKills[c], totKills));
        EnviarLinea(c, buf);
    }

    // rango CI (por comunes)
    int rankCI = 1;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!ContarEnStats(i) || i == c) continue;
        if (g_iComunes[i] > g_iComunes[c]) rankCI++;
    }
    if (rankCI <= 4 && g_iComunes[c] > 0)   // hasta el puesto 4 y con datos propios
    {
        Format(buf, sizeof buf, "\x04Tu rango CI\x01 » \x05#%d\x01 · \x05%d\x01 comunes \x05[%d%%]",
            rankCI, g_iComunes[c], Pct(g_iComunes[c], totCom));
        EnviarLinea(c, buf);
    }

    // fuego amigo propio (si hizo)
    if (g_iFF[c] > 0)
    {
        int rankFF = 1;   // #1 = el que mas fuego amigo hizo
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!ContarEnStats(i) || i == c) continue;
            if (g_iFF[i] > g_iFF[c]) rankFF++;
        }
        if (rankFF <= 4)   // solo se muestra hasta el puesto 4
        {
            Format(buf, sizeof buf, "\x04Tu rango FF\x01 » \x05#%d\x01 · \x05%d\x01 fuego amigo \x05[%d%%]",
                rankFF, g_iFF[c], Pct(g_iFF[c], totFF));
            EnviarLinea(c, buf);
        }
    }
}

bool ContarEnStats(int i)
{
    if (i < 1 || i > MaxClients || !IsClientInGame(i)) return false;
    if (IsFakeClient(i)) return g_cvBots.BoolValue;
    return true;
}

// Calcula quien va MVP SI, MVP CI y LVP FF con las stats actuales, y los totales para los %
void ComputeStandings(int &mvpSI, int &mvpCI, int &lvpFF,
                      int &totSI, int &totKills, int &totCI, int &totFF)
{
    totSI = 0; totKills = 0; totCI = 0; totFF = 0;
    mvpSI = 0; mvpCI = 0; lvpFF = 0;
    int bestSI = -1, bestCI = -1, worstFF = -1;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!ContarEnStats(i)) continue;
        totSI    += g_iSIDano[i];
        totKills += g_iKills[i];
        totCI    += g_iComunes[i];
        totFF    += g_iFF[i];
        if (g_iSIDano[i]  > bestSI)  { bestSI = g_iSIDano[i]; mvpSI = i; }
        if (g_iComunes[i] > bestCI)  { bestCI = g_iComunes[i]; mvpCI = i; }
        if (g_iFF[i]      > worstFF) { worstFF = g_iFF[i]; lvpFF = i; }
    }
}

void EnviarLinea(int target, const char[] msg)
{
    if (target == 0) PrintToChatAll("%s", msg);
    else if (target >= 1 && target <= MaxClients && IsClientInGame(target)) PrintToChat(target, "%s", msg);
}

// Nombre para mostrar; a los bots les agrega [BOT]
void NombreMostrar(int client, char[] out, int maxlen)
{
    GetClientName(client, out, maxlen);
    if (IsFakeClient(client))
        Format(out, maxlen, "%s \x05[BOT]\x03", out);
}

// Muestra el MVP SI, MVP CI y LVP FF con las stats actuales.
// target 0 = a todos; >0 = solo a ese cliente (y le agrega su rango personal). No premia ni resetea.
void MostrarTabla(int target)
{
    int mvpSI, mvpCI, lvpFF, totSI, totKills, totCI, totFF;
    ComputeStandings(mvpSI, mvpCI, lvpFF, totSI, totKills, totCI, totFF);
    int ffMin = g_cvFFMin.IntValue;
    char buf[256], dn[96];

    // MVP SI
    if (mvpSI > 0 && g_iSIDano[mvpSI] > 0)
    {
        NombreMostrar(mvpSI, dn, sizeof dn);
        Format(buf, sizeof buf, "\x04★ [MVP] SI\x01 » \x03%s\x01 · \x05%d\x01 daño \x05[%d%%]\x01 · \x05%d\x01 bajas \x05[%d%%]",
            dn, g_iSIDano[mvpSI], Pct(g_iSIDano[mvpSI], totSI), g_iKills[mvpSI], Pct(g_iKills[mvpSI], totKills));
        EnviarLinea(target, buf);
    }
    else EnviarLinea(target, "\x04★ [MVP] SI\x01 » sin datos");

    // MVP CI
    if (mvpCI > 0 && g_iComunes[mvpCI] > 0)
    {
        NombreMostrar(mvpCI, dn, sizeof dn);
        Format(buf, sizeof buf, "\x04★ [MVP] CI\x01 » \x03%s\x01 · \x05%d\x01 comunes \x05[%d%%]",
            dn, g_iComunes[mvpCI], Pct(g_iComunes[mvpCI], totCI));
        EnviarLinea(target, buf);
    }
    else EnviarLinea(target, "\x04★ [MVP] CI\x01 » sin datos");

    // LVP FF
    if (lvpFF > 0 && g_iFF[lvpFF] >= ffMin)
    {
        NombreMostrar(lvpFF, dn, sizeof dn);
        Format(buf, sizeof buf, "\x04▼ [LVP] FF\x01 » \x03%s\x01 · \x05%d\x01 fuego amigo \x05[%d%%]",
            dn, g_iFF[lvpFF], Pct(g_iFF[lvpFF], totFF));
        EnviarLinea(target, buf);
    }
    else EnviarLinea(target, "\x04▼ [LVP] FF\x01 » sin fuego amigo");

    // Tu rango personal: si target>0 solo a el; si es el anuncio de ronda (target<=0), a cada jugador
    if (target > 0) RangoPersonal(target, totSI, totKills, totCI, totFF);
    else
    {
        for (int i = 1; i <= MaxClients; i++)
            if (IsClientInGame(i) && !IsFakeClient(i)) RangoPersonal(i, totSI, totKills, totCI, totFF);
    }

}

void AwardBestPerformers()
{
    if (!g_cvActivo.BoolValue) return;

    if (g_cvAnuncio.BoolValue)
        MostrarTabla(0);
    ConsolaStats(0);   // tabla completa en la consola de todos
    CampAcumular();    // suma esta ronda al resumen de la campaña

    ResetRoundAll();
}

// ============================ DISPARADOR ============================

void StartPrestige()
{
    if (!g_cvActivo.BoolValue) return;
    AwardBestPerformers();
}


// ============================ COMANDOS ============================

public Action Cmd_Rendimiento(int client, int args)
{
    if (client < 1) return Plugin_Handled;
    PrintToChat(client, "\x04[Prestigio]\x01 Rendimiento de la ronda:");
    MostrarTabla(client);
    return Plugin_Handled;
}

public Action Cmd_Iniciar(int client, int args)
{
    StartPrestige();
    return Plugin_Handled;
}

public Action Cmd_IniciarSrv(int args)
{
    StartPrestige();
    return Plugin_Handled;
}

public Action Cmd_Reset(int client, int args)
{
    ResetRoundAll();
    ReplyToCommand(client, "[Prestigio] Stats de la ronda reiniciadas.");
    return Plugin_Handled;
}

public Action Cmd_ResetSrv(int args)
{
    ResetRoundAll();
    PrintToServer("[Prestigio] Stats de la ronda reiniciadas.");
    return Plugin_Handled;
}

// ============================================================================
//  SKILLS: lógica portada de l4d2_skill_detect (ZoneMod), sin left4dhooks ni skill_detect
// ============================================================================

void SkInit()
{
    char nm[48], ds[200];
    for (int i = 0; i < SK_COUNT; i++)
    {
        Format(nm, sizeof nm, "cc_prestigio_sk_%s", g_sSkNom[i]);
        Format(ds, sizeof ds, "1 = anuncia: %s.", g_sSkDes[i]);
        g_cvSk[i] = CreateConVar(nm, g_sSkDef[i], ds, FCVAR_NOTIFY, true, 0.0, true, 1.0);
    }
    g_cvHunterDPAlt  = CreateConVar("cc_prestigio_hunterdp_altura", "400", "Altura minima (unidades) para que un pounce de Hunter cuente como high pounce.", FCVAR_NOTIFY, true, 0.0);
    g_cvJockeyDPAlt  = CreateConVar("cc_prestigio_jockeydp_altura", "300", "Altura minima (unidades) para que un salto de Jockey cuente como high pounce.", FCVAR_NOTIFY, true, 0.0);
    g_cvDrawCrownMin = CreateConVar("cc_prestigio_drawcrown_dano", "500", "Daño minimo del ultimo escopetazo para que cuente como draw crown.", FCVAR_NOTIFY, true, 0.0);
    g_cvDCAlt        = CreateConVar("cc_prestigio_deathcharge_altura", "400", "Altura minima que debe llevar el Charger a su victima para anunciar el death charge.", FCVAR_NOTIFY, true, 0.0);
    g_cvBhopMin      = CreateConVar("cc_prestigio_bhop_min", "3", "Racha minima de saltos para avisar del bunnyhop.", FCVAR_NOTIFY, true, 1.0);
    g_cvBhopInit     = CreateConVar("cc_prestigio_bhop_vel_inicial", "150", "Velocidad minima del primer salto de una racha de bunnyhop.", FCVAR_NOTIFY, true, 0.0);
    g_cvBhopCont     = CreateConVar("cc_prestigio_bhop_vel_continua", "300", "Velocidad desde la cual se sigue contando la racha aunque no acelere.", FCVAR_NOTIFY, true, 0.0);
    RegConsoleCmd("sm_campana", Cmd_Campana, "Muestra en tu consola el resumen acumulado de la campaña.");
    HookEventEx("versus_match_finished", Event_CampFin, EventHookMode_PostNoCopy);
    HookEventEx("finale_win", Event_CampFin, EventHookMode_PostNoCopy);
    RegConsoleCmd("sm_skills", Cmd_Skills, "Muestra en tu consola la tabla de skills de la ronda.");
    g_cvVomitMin     = CreateConVar("cc_prestigio_vomit_min", "3", "Supervivientes minimos vomitados por un mismo Boomer para anunciarlo.", FCVAR_NOTIFY, true, 1.0);

    g_cvPounceInt    = FindConVar("z_pounce_damage_interrupt");
    g_cvChargerHp    = FindConVar("z_charger_health");
    g_cvPounceMin    = FindConVar("z_pounce_damage_range_min");
    g_cvPounceMax    = FindConVar("z_pounce_damage_range_max");
    g_cvPounceDmgMax = FindConVar("z_hunter_max_pounce_bonus_damage");
    if (g_cvPounceInt != null)
    {
        g_iPounceInterrupt = g_cvPounceInt.IntValue;
        g_cvPounceInt.AddChangeHook(Cvar_PounceInt);
    }

    g_smCars = new StringMap();

    HookEvent("player_hurt",        Event_SkHurt, EventHookMode_Pre);
    HookEvent("player_shoved",      Event_SkShoved);
    HookEvent("lunge_pounce",       Event_SkLunge);
    HookEvent("jockey_ride",        Event_SkJockeyRide);
    HookEvent("player_jump",        Event_SkJump);
    HookEvent("player_jump_apex",   Event_SkJumpApex);
    HookEvent("player_now_it",      Event_SkBoomed);
    HookEvent("boomer_exploded",    Event_SkBoomerExploded);
    HookEvent("witch_harasser_set", Event_SkWitchHarasser);
    HookEvent("charger_carry_start",Event_SkChargeCarryStart);
    HookEvent("charger_carry_end",  Event_SkChargeCarryEnd);
    HookEvent("charger_impact",     Event_SkChargeImpact);
    HookEvent("player_incapacitated_start", Event_SkIncapStart);
    HookEvent("triggered_car_alarm",Event_SkCarAlarm);
}

public void Cvar_PounceInt(ConVar convar, const char[] oldValue, const char[] newValue)
{
    g_iPounceInterrupt = convar.IntValue;
}

float SkCvF(ConVar cv, float def)
{
    return (cv != null) ? cv.FloatValue : def;
}

// ¿este skill esta activado? (los de hunter/charger tambien respetan cc_prestigio_skeet)
bool SkOn(int k)
{
    if (!g_cvActivo.BoolValue || !g_cvSk[k].BoolValue) return false;
    if (k <= SK_DEADSTOP && !g_cvSkeet.BoolValue) return false;
    return true;
}

bool SkSurv(int c)
{
    return (c >= 1 && c <= MaxClients && IsClientInGame(c) && GetClientTeam(c) == 2);
}

bool SkInf(int c)
{
    return (c >= 1 && c <= MaxClients && IsClientInGame(c) && GetClientTeam(c) == 3);
}

// los bots solo salen en los anuncios si cc_prestigio_bots = 1
bool SkVisible(int c)
{
    return !(IsFakeClient(c) && !g_cvBots.BoolValue);
}

void SkRoundStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bIsHopping[i] = false;
        g_iHops[i] = 0;
        for (int j = 1; j <= MaxClients; j++) g_fLastShoveT[i][j] = 0.0;
    }
}

void SkRoundEnd()
{
    if (g_smCars != null) g_smCars.Clear();   // los autos se crean de nuevo cada ronda
}

void SkResetHunter(int client)
{
    g_iHunterShotDmgTeam[client] = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_iHunterShotDmg[client][i] = 0;
        g_fHunterShotStart[client][i] = 0.0;
    }
    g_iHunterOverkill[client] = 0;
    g_bHunterKilledPouncing[client] = false;
}

// Se llama desde Event_PlayerSpawn
void SkOnSpawn(int client)
{
    int zc = GetEntProp(client, Prop_Send, "m_zombieClass");
    switch (zc)
    {
        case SK_ZC_BOOMER:
        {
            g_bBoomerHit[client] = false;
            g_iBoomerShoved[client] = 0;
        }
        case SK_ZC_HUNTER:
        {
            SkResetHunter(client);
            g_fHunterTracePouncing[client] = 0.0;
            g_fPouncePos[client][0] = 0.0; g_fPouncePos[client][1] = 0.0; g_fPouncePos[client][2] = 0.0;
            g_iHunterLastHealth[client] = GetClientHealth(client);
        }
        case SK_ZC_JOCKEY:
        {
            g_fPouncePos[client][0] = 0.0; g_fPouncePos[client][1] = 0.0; g_fPouncePos[client][2] = 0.0;
        }
    }
}

// TraceAttack en cada cliente: marca el instante en que se disparo a un hunter en pleno salto
public Action Hook_SkTrace(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &ammotype, int hitbox, int hitgroup)
{
    if (!SkInf(victim) || !SkSurv(attacker) || inflictor <= 0 || !IsValidEdict(inflictor)) return Plugin_Continue;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") != SK_ZC_HUNTER) return Plugin_Continue;
    if (GetEntProp(victim, Prop_Send, "m_isAttemptingToPounce"))
        g_fHunterTracePouncing[victim] = GetGameTime();
    else
        g_fHunterTracePouncing[victim] = 0.0;
    return Plugin_Continue;
}

// ----------------------------------------------------------------------------
//  player_hurt: skeets, levels, daño de pounce, flags de death charge
// ----------------------------------------------------------------------------
public Action Event_SkHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return Plugin_Continue;

    int victim     = GetClientOfUserId(event.GetInt("userid"));
    int attacker   = GetClientOfUserId(event.GetInt("attacker"));
    int damage     = event.GetInt("dmg_health");
    int damagetype = event.GetInt("type");

    if (SkInf(victim))
    {
        int zc       = GetEntProp(victim, Prop_Send, "m_zombieClass");
        int health   = event.GetInt("health");
        int hitgroup = event.GetInt("hitgroup");
        if (damage < 1) return Plugin_Continue;

        if (zc == SK_ZC_HUNTER)       SkHunterHurt(event, victim, attacker, damage, damagetype, health, hitgroup);
        else if (zc == SK_ZC_CHARGER) SkChargerHurt(victim, attacker, damage, damagetype, health);
    }
    else if (SkInf(attacker))
    {
        // el aterrizaje de un pounce es DMG_CRUSH: daño real del pounce
        if (GetEntProp(attacker, Prop_Send, "m_zombieClass") == SK_ZC_HUNTER && (damagetype & DMG_CRUSH))
            g_iPounceDamage[attacker] = damage;
    }

    // flags de death charge (daño por caida / ahogamiento / mapa)
    if (SkSurv(victim))
    {
        if (damagetype & (DMG_DROWN | DMG_FALL)) g_iVictimMapDmg[victim] += damage;
        if ((damagetype & DMG_DROWN) && damage >= SK_DC_TRIGGER_DMG)
            g_iVictimFlags[victim] |= SK_VF_HURTLOTS;
        else if ((damagetype & DMG_FALL) && damage >= SK_DC_FALL_DMG)
            g_iVictimFlags[victim] |= SK_VF_HURTLOTS;
    }
    return Plugin_Continue;
}

bool SkWeaponSniper(const char[] w)
{
    return (StrEqual(w, "hunting_rifle") || StrEqual(w, "sniper_military") || StrEqual(w, "sniper_awp")
         || StrEqual(w, "sniper_scout") || StrEqual(w, "pistol_magnum"));
}

void SkHunterHurt(Event event, int victim, int attacker, int damage, int damagetype, int health, int hitgroup)
{
    // si no lo daña un superviviente, solo se anota la vida que le queda
    if (!SkSurv(attacker))
    {
        g_iHunterLastHealth[victim] = health;
        return;
    }

    // si el daño supera la vida que se sabia que tenia, se recorta (sobrante = overkill)
    if (g_iHunterLastHealth[victim] > 0 && damage > g_iHunterLastHealth[victim])
    {
        g_iHunterOverkill[victim] = damage - g_iHunterLastHealth[victim];
        damage = g_iHunterLastHealth[victim];
        g_iHunterLastHealth[victim] = 0;
    }

    // un escopetazo viejo ya no es el mismo disparo
    float now = GetGameTime();
    if (g_iHunterShotDmg[victim][attacker] > 0 && (now - g_fHunterShotStart[victim][attacker]) > SK_SHOTGUN_BLAST)
        g_fHunterShotStart[victim][attacker] = 0.0;

    // m_isAttemptingToPounce pasa a 0 si el hunter muere en este golpe: por eso tambien se mira el TraceAttack previo
    bool pouncing = (GetEntProp(victim, Prop_Send, "m_isAttemptingToPounce") != 0)
                 || (g_fHunterTracePouncing[victim] != 0.0 && (now - g_fHunterTracePouncing[victim]) < 0.001);

    if (pouncing)
    {
        char weapon[32];
        event.GetString("weapon", weapon, sizeof weapon);

        if (damagetype & DMG_BUCKSHOT)
        {
            // primer perdigon de un escopetazo nuevo
            if (g_fHunterShotStart[victim][attacker] == 0.0)
                g_fHunterShotStart[victim][attacker] = now;
            g_iHunterShotDmg[victim][attacker] += damage;
            g_iHunterShotDmgTeam[victim] += damage;
            if (health == 0) g_bHunterKilledPouncing[victim] = true;
        }
        else if (health == 0 && StrEqual(weapon, "grenade_launcher_projectile"))
        {
            // golpe directo de lanzagranadas
            SkAnnSkeet(attacker, victim, 3);
            SkResetHunter(victim);
        }
        else if ((damagetype & DMG_BULLET) && health == 0 && hitgroup == SK_HITGROUP_HEAD)
        {
            // tiro a la cabeza con arma de un solo disparo (sniper / magnum)
            if (SkWeaponSniper(weapon))
            {
                if (damage >= g_iPounceInterrupt)
                {
                    g_iHunterShotDmgTeam[victim] = 0;
                    SkAnnSkeet(attacker, victim, 2);
                }
                else
                {
                    SkAnnHurtSkeet(attacker, victim, damage, (g_iHunterOverkill[victim] + g_iHunterShotDmgTeam[victim] > g_iPounceInterrupt));
                }
                SkResetHunter(victim);
            }
        }
        else if (damagetype & (DMG_SLASH | DMG_CLUB))
        {
            // melee
            if (damage >= g_iPounceInterrupt)
            {
                g_iHunterShotDmgTeam[victim] = 0;
                SkAnnSkeet(attacker, victim, 1);
                SkResetHunter(victim);
            }
            else if (health == 0)
            {
                SkAnnHurtSkeet(attacker, victim, damage, true);
                SkResetHunter(victim);
            }
        }
    }
    else if (health == 0)
    {
        g_bHunterKilledPouncing[victim] = false;   // murio sin estar en el aire: no es skeet
    }

    g_iHunterLastHealth[victim] = health;
}

void SkChargerHurt(int victim, int attacker, int damage, int damagetype, int health)
{
    if (!SkSurv(attacker) || health != 0 || !(damagetype & (DMG_CLUB | DMG_SLASH))) return;
    int ab = GetEntPropEnt(victim, Prop_Send, "m_customAbility");
    if (ab <= 0 || !IsValidEntity(ab) || !HasEntProp(ab, Prop_Send, "m_isCharging")) return;
    if (!GetEntProp(ab, Prop_Send, "m_isCharging")) return;

    float chHp = (g_cvChargerHp != null) ? g_cvChargerHp.FloatValue : 600.0;
    if (float(damage) > chHp * 0.65)
        SkAnnLevel(attacker, victim);
    else
        SkAnnLevelHurt(attacker, victim, damage);
}

// ----------------------------------------------------------------------------
//  Muertes: skeet de escopeta / en equipo, flags de death charge
// ----------------------------------------------------------------------------
void SkOnDeath(int victim, int attacker, Event event)
{
    if (SkInf(victim))
    {
        int zc = GetEntProp(victim, Prop_Send, "m_zombieClass");
        if (zc == SK_ZC_HUNTER)
        {
            if (SkSurv(attacker) && g_iHunterShotDmgTeam[victim] > 0 && g_bHunterKilledPouncing[victim])
            {
                int propio = g_iHunterShotDmg[victim][attacker];
                int equipo = g_iHunterShotDmgTeam[victim];
                if (equipo > propio && equipo >= g_iPounceInterrupt)
                    SkAnnSkeet(-2, victim, 0);                       // skeet en equipo
                else if (propio >= g_iPounceInterrupt)
                    SkAnnSkeet(attacker, victim, 0);                 // skeet de un solo jugador
                else if (g_iHunterOverkill[victim] > 0)
                    SkAnnHurtSkeet(attacker, victim, equipo, (g_iHunterOverkill[victim] + equipo > g_iPounceInterrupt));
                else
                    SkAnnHurtSkeet(attacker, victim, propio, false);
            }
            SkResetHunter(victim);
        }
        else if (zc == SK_ZC_CHARGER)
        {
            // si llevaba a alguien, se pasa a revisar su impacto
            if (SkSurv(g_iChargeVictim[victim])) g_fChargeTime[g_iChargeVictim[victim]] = GetGameTime();
        }
    }
    else if (SkSurv(victim))
    {
        int dmgtype = event.GetInt("type");
        if (dmgtype & DMG_FALL)
            g_iVictimFlags[victim] |= SK_VF_FALL;
        else if (SkInf(attacker) && attacker != g_iVictimCharger[victim])
            g_iVictimFlags[victim] |= SK_VF_OTHERKILL;   // lo mato otro especial: no es death charge
    }
}

// ----------------------------------------------------------------------------
//  Empujones: deadstop y conteo en boomers
// ----------------------------------------------------------------------------
public void Event_SkShoved(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int victim   = GetClientOfUserId(event.GetInt("userid"));
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (!SkSurv(attacker) || !SkInf(victim)) return;

    int zc = GetEntProp(victim, Prop_Send, "m_zombieClass");
    if (zc == SK_ZC_BOOMER) g_iBoomerShoved[victim]++;

    float now = GetGameTime();
    if (g_fLastShoveT[victim][attacker] == 0.0 || (now - g_fLastShoveT[victim][attacker]) >= SK_SHOVE_TIME)
    {
        if (zc == SK_ZC_HUNTER && GetEntProp(victim, Prop_Send, "m_isAttemptingToPounce"))
            SkAnnDeadstop(attacker, victim);
        SkAnnShove(attacker, victim);
        g_fLastShoveT[victim][attacker] = now;
    }
}

// ----------------------------------------------------------------------------
//  Boomer: explotado sin vomitar / vomito a varios
// ----------------------------------------------------------------------------
public void Event_SkBoomed(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    bool byBoom  = event.GetBool("by_boomer");
    if (!byBoom || !SkInf(attacker)) return;

    g_bBoomerHit[attacker] = true;
    if (!event.GetBool("exploded"))   // vomito (no explosion)
    {
        if (g_iVomitHits[attacker] == 0)
            CreateTimer(SK_VOMIT_TIME, Timer_SkVomit, GetClientUserId(attacker), TIMER_FLAG_NO_MAPCHANGE);
        g_iVomitHits[attacker]++;
    }
}

public Action Timer_SkVomit(Handle timer, any userid)
{
    int boomer = GetClientOfUserId(userid);
    if (boomer >= 1 && boomer <= MaxClients)
    {
        int n = g_iVomitHits[boomer];
        g_iVomitHits[boomer] = 0;
        if (n >= g_cvVomitMin.IntValue) SkAnnVomit(boomer, n);
    }
    return Plugin_Stop;
}

public void Event_SkBoomerExploded(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int client   = GetClientOfUserId(event.GetInt("userid"));
    bool biled   = event.GetBool("splashedbile");
    if (client < 1 || client > MaxClients) return;
    if (!biled && !g_bBoomerHit[client])
    {
        int attacker = GetClientOfUserId(event.GetInt("attacker"));
        if (SkSurv(attacker)) SkAnnPop(attacker);
    }
}

// ----------------------------------------------------------------------------
//  High pounce (hunter / jockey)
// ----------------------------------------------------------------------------
void SkOnAbilityLunge(int client)
{
    // el hunter empezo un pounce: se guarda desde donde salto
    SkResetHunter(client);
    GetClientAbsOrigin(client, g_fPouncePos[client]);
}

public void Event_SkLunge(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (!SkInf(client)) return;

    SkResetHunter(client);   // ya aterrizo: no hay skeet pendiente

    if (g_fPouncePos[client][0] == 0.0 && g_fPouncePos[client][1] == 0.0 && g_fPouncePos[client][2] == 0.0) return;

    float endPos[3];
    GetClientAbsOrigin(client, endPos);
    float fHeight = g_fPouncePos[client][2] - endPos[2];

    // formula de daño del juego (distancia entre el punto de salto y el de aterrizaje)
    float fMin    = SkCvF(g_cvPounceMin, 300.0);
    float fMax    = SkCvF(g_cvPounceMax, 1000.0);
    float fMaxDmg = SkCvF(g_cvPounceDmgMax, 49.0);
    int distance  = RoundToNearest(GetVectorDistance(g_fPouncePos[client], endPos));
    float fDamage = (((float(distance) - fMin) / (fMax - fMin)) * fMaxDmg) + 1.0;
    if (fDamage < 0.0) fDamage = 0.0;
    else if (fDamage > fMaxDmg + 1.0) fDamage = fMaxDmg + 1.0;

    g_iPounceDamage[client] = 0;   // el daño real llega justo despues, por player_hurt (DMG_CRUSH)

    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(victim > 0 ? GetClientUserId(victim) : 0);
    pack.WriteFloat(fDamage);
    pack.WriteFloat(fHeight);
    CreateTimer(0.05, Timer_SkHunterDP, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_SkHunterDP(Handle timer, DataPack pack)
{
    pack.Reset();
    int client   = GetClientOfUserId(pack.ReadCell());
    int victim   = GetClientOfUserId(pack.ReadCell());
    float calc   = pack.ReadFloat();
    float height = pack.ReadFloat();
    if (client < 1 || !SkInf(client) || !SkSurv(victim)) return Plugin_Stop;

    // se muestra el daño real aplicado; si no llego a medirse, el calculado por la formula
    int dmg = (g_iPounceDamage[client] > 0) ? g_iPounceDamage[client] : RoundFloat(calc);
    if (height >= g_cvHunterDPAlt.FloatValue) SkAnnHunterDP(client, victim, dmg, height);
    return Plugin_Stop;
}

public void Event_SkJockeyRide(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (!SkInf(client) || !SkSurv(victim)) return;
    if (g_fPouncePos[client][0] == 0.0 && g_fPouncePos[client][1] == 0.0 && g_fPouncePos[client][2] == 0.0) return;

    float endPos[3];
    GetClientAbsOrigin(client, endPos);
    float fHeight = g_fPouncePos[client][2] - endPos[2];

    if (fHeight >= g_cvJockeyDPAlt.FloatValue) SkAnnJockeyDP(client, victim, fHeight);
}

// ----------------------------------------------------------------------------
//  Saltos: origen del jockey y rachas de bunnyhop de los supervivientes
// ----------------------------------------------------------------------------
public void Event_SkJump(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !IsClientInGame(client)) return;

    if (SkInf(client))
    {
        if (GetEntProp(client, Prop_Send, "m_zombieClass") == SK_ZC_JOCKEY)
            GetClientAbsOrigin(client, g_fPouncePos[client]);   // de donde salto el jockey
        return;
    }
    if (!SkSurv(client)) return;

    float fVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", fVel);
    fVel[2] = 0.0;
    float fLengthNew = GetVectorLength(fVel);
    g_bHopCheck[client] = false;

    if (!g_bIsHopping[client])
    {
        if (fLengthNew >= g_cvBhopInit.FloatValue)
        {
            g_fHopTop[client] = fLengthNew;   // posible inicio de racha
            g_bIsHopping[client] = true;
            g_iHops[client] = 0;
        }
    }
    else
    {
        float fLengthOld = GetVectorLength(g_fLastHop[client]);
        // si gano velocidad (o ya va rapido) cuenta como salto de la racha; si no, la racha termino
        if (fLengthNew - fLengthOld > SK_HOP_ACCEL || fLengthNew >= g_cvBhopCont.FloatValue)
        {
            g_iHops[client]++;
            if (fLengthNew > g_fHopTop[client]) g_fHopTop[client] = fLengthNew;
        }
        else
        {
            g_bIsHopping[client] = false;
            if (g_iHops[client])
            {
                SkAnnBhop(client, g_iHops[client], g_fHopTop[client]);
                g_iHops[client] = 0;
            }
        }
    }

    g_fLastHop[client][0] = fVel[0];
    g_fLastHop[client][1] = fVel[1];
    g_fLastHop[client][2] = fVel[2];

    if (g_iHops[client] != 0)
        CreateTimer(SK_HOP_CHECK, Timer_SkCheckHop, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SkCheckHop(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client)) return Plugin_Stop;

    if (GetEntityFlags(client) & FL_ONGROUND)
    {
        g_bHopCheck[client] = true;   // volvio al suelo: se confirma el fin de la racha poco despues
        CreateTimer(SK_HOPEND_CHECK, Timer_SkCheckHopStreak, userid, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

public Action Timer_SkCheckHopStreak(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client) || !IsPlayerAlive(client)) return Plugin_Stop;

    if (g_bHopCheck[client] && g_iHops[client])
    {
        SkAnnBhop(client, g_iHops[client], g_fHopTop[client]);
        g_bIsHopping[client] = false;
        g_iHops[client] = 0;
        g_fHopTop[client] = 0.0;
    }
    g_bHopCheck[client] = false;
    return Plugin_Stop;
}

public void Event_SkJumpApex(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients || !g_bIsHopping[client]) return;
    float fVel[3];
    GetEntPropVector(client, Prop_Data, "m_vecVelocity", fVel);
    fVel[2] = 0.0;
    float fLength = GetVectorLength(fVel);
    if (fLength > g_fHopTop[client]) g_fHopTop[client] = fLength;
}

// ----------------------------------------------------------------------------
//  Death charge
// ----------------------------------------------------------------------------
public void Event_SkChargeCarryStart(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (!SkInf(client)) return;

    g_fChargeTime[client] = GetGameTime();
    if (!SkSurv(victim)) return;

    g_iChargeVictim[client]  = victim;   // mientras este seteado, no es un vuelo por impacto
    g_iVictimCharger[victim] = client;
    g_iVictimFlags[victim]   = SK_VF_CARRIED;
    g_bDCAnn[victim]         = false;
    g_fChargeTime[victim]    = g_fChargeTime[client];
    g_iVictimMapDmg[victim]  = 0;
    GetClientAbsOrigin(victim, g_fChargeVictimPos[victim]);
    CreateTimer(SK_CHARGE_CHECK, Timer_SkChargeCheck, GetClientUserId(victim), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_SkChargeImpact(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue) return;
    int client = GetClientOfUserId(event.GetInt("userid"));
    int victim = GetClientOfUserId(event.GetInt("victim"));
    if (!SkInf(client) || !SkSurv(victim)) return;

    GetClientAbsOrigin(victim, g_fChargeVictimPos[victim]);
    g_iVictimCharger[victim] = client;
    g_iVictimFlags[victim]   = 0;
    g_bDCAnn[victim]         = false;
    g_fChargeTime[victim]    = GetGameTime();
    g_iVictimMapDmg[victim]  = 0;
    CreateTimer(SK_CHARGE_CHECK, Timer_SkChargeCheck, GetClientUserId(victim), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_SkChargeCarryEnd(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients) return;
    // pequeña espera: asi se puede ver si el charger murio a mitad del arrastre
    CreateTimer(0.1, Timer_SkChargeCarryEnd, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_SkChargeCarryEnd(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client >= 1) g_iChargeVictim[client] = 0;
    return Plugin_Stop;
}

public void Event_SkIncapStart(Event event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client < 1 || client > MaxClients) return;
    if (event.GetInt("type") & DMG_DROWN) g_iVictimFlags[client] |= SK_VF_DROWN;
}

public Action Timer_SkChargeCheck(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    // si algo fallo o paso demasiado tiempo, se olvida
    if (!SkSurv(client) || !g_iVictimCharger[client] || g_fChargeTime[client] == 0.0
        || (GetGameTime() - g_fChargeTime[client]) > SK_MAX_CHARGE_TIME)
        return Plugin_Stop;

    if (!IsPlayerAlive(client))
    {
        // murio en el aire: probablemente death charge
        g_iVictimFlags[client] |= SK_VF_AIRDEATH;
        CreateTimer(0.0, Timer_SkDeathChargeCheck, userid, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }
    else if ((GetEntityFlags(client) & FL_ONGROUND) && g_iChargeVictim[g_iVictimCharger[client]] != client)
    {
        // llego al suelo y ya no lo lleva el charger: se revisa con un poco de espera (por si muere enseguida)
        CreateTimer(SK_CHARGE_END, Timer_SkDeathChargeCheck, userid, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

public Action Timer_SkDeathChargeCheck(Handle timer, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client < 1 || !IsClientInGame(client)) return Plugin_Stop;

    int flags = g_iVictimFlags[client];
    if (!IsPlayerAlive(client))
    {
        float pos[3];
        GetClientAbsOrigin(client, pos);
        float fHeight = g_fChargeVictimPos[client][2] - pos[2];

        // death charge: murio ahogado/por caida habiendo recibido mucho daño o en el aire,
        // o recibio mucho daño del mapa; y no lo mato otro especial
        bool cond = (((flags & (SK_VF_DROWN | SK_VF_FALL)) != 0 && (flags & (SK_VF_HURTLOTS | SK_VF_AIRDEATH)) != 0)
                     || g_iVictimMapDmg[client] >= SK_DC_TRIGGER_DMG);
        if (cond && !(flags & SK_VF_OTHERKILL) && !g_bDCAnn[client])
        {
            g_bDCAnn[client] = true;
            SkAnnDeathCharge(g_iVictimCharger[client], client, fHeight, (flags & SK_VF_CARRIED) != 0);
        }
    }
    else if (g_iVictimMapDmg[client] >= SK_DC_RECHECK_DMG && !(flags & (1 << 8)))
    {
        // puede estar caido y muriendo mas lento: se revisa una vez mas
        g_iVictimFlags[client] |= (1 << 8);
        CreateTimer(SK_CHARGE_RECHECK, Timer_SkDeathChargeCheck, userid, TIMER_FLAG_NO_MAPCHANGE);
    }
    return Plugin_Stop;
}

// ----------------------------------------------------------------------------
//  Witch: crown / draw crown
// ----------------------------------------------------------------------------
void SkWitchReset(int witch)
{
    if (witch < 0 || witch >= sizeof(g_iWCrCrowner)) return;
    for (int i = 0; i <= MaxClients; i++) g_iWCrDmg[witch][i] = 0;
    g_iWCrCrowner[witch] = 0;
    g_iWCrShot[witch] = 0;
    g_iWCrType[witch] = 0;
    g_bWCrSlash[witch] = false;
    g_bWCrStartled[witch] = false;
}

// Se llama desde Hook_WitchDamagePost por cada golpe a la witch
void SkWitchDamage(int witch, int attacker, float damage, int damagetype)
{
    if (witch < 0 || witch >= sizeof(g_iWCrCrowner)) return;
    int dmg = RoundToFloor(damage);
    if (SkSurv(attacker))
    {
        g_iWCrDmg[witch][attacker] += dmg;
        float now = GetGameTime();
        // ultimo disparo (un escopetazo = pellets dentro de 0.1 s)
        if (g_fWCrShotStart[attacker] == 0.0 || (now - g_fWCrShotStart[attacker]) > SK_SHOTGUN_BLAST)
        {
            g_fWCrShotStart[attacker] = now;
            g_iWCrCrowner[witch] = attacker;
            g_iWCrShot[witch] = 0;
            g_iWCrType[witch] = (damagetype & DMG_BUCKSHOT) ? 1 : 0;   // solo cuenta la escopeta
        }
        g_iWCrShot[witch] += dmg;
    }
    else
    {
        g_iWCrDmg[witch][0] += dmg;   // daño de otras fuentes (chip)
    }
}

public void Event_SkWitchHarasser(Event event, const char[] name, bool dontBroadcast)
{
    int witch = event.GetInt("witchid");
    if (witch > 0 && witch < sizeof(g_bWCrStartled)) g_bWCrStartled[witch] = true;
}

// Se llama desde Event_WitchKilled
void SkWitchKilled(int witch, int attacker, bool oneshot)
{
    if (!SkSurv(attacker) || witch <= 0 || witch >= sizeof(g_bWCrStartled)) return;
    DataPack pack = new DataPack();
    pack.WriteCell(witch);
    pack.WriteCell(GetClientUserId(attacker));
    pack.WriteCell(oneshot ? 1 : 0);
    CreateTimer(SK_WITCH_CHECK, Timer_SkCrown, pack, TIMER_FLAG_NO_MAPCHANGE | TIMER_DATA_HNDL_CLOSE);
}

public Action Timer_SkCrown(Handle timer, DataPack pack)
{
    pack.Reset();
    int witch    = pack.ReadCell();
    int attacker = GetClientOfUserId(pack.ReadCell());
    bool oneshot = (pack.ReadCell() != 0);
    if (SkSurv(attacker)) SkCheckCrown(witch, attacker, oneshot);
    return Plugin_Stop;
}

void SkCheckCrown(int witch, int attacker, bool oneshot)
{
    int health = VidaWitch();
    if (oneshot) g_iWCrType[witch] = 1;

    // si la witch le pego a alguien o el ultimo tiro no fue de escopeta, no hay crown
    if (g_bWCrSlash[witch] || !g_iWCrType[witch]) { SkWitchReset(witch); return; }

    // chip = daño de cualquier otro (y de otras fuentes)
    int chip = 0;
    for (int i = 0; i <= MaxClients; i++)
        if (i != attacker) chip += g_iWCrDmg[witch][i];

    if (!g_bWCrStartled[witch] && (oneshot || g_iWCrShot[witch] >= health))
    {
        // crown completo: sin asustarla y de un solo escopetazo. Daño = vida total - chip ajeno (exacto)
        int dmg = health - chip;
        if (dmg < 1) dmg = health;
        SkAnnCrown(attacker, dmg);
    }
    else if (g_iWCrShot[witch] >= g_cvDrawCrownMin.IntValue)
    {
        // draw crown: asustada, pero un solo escopetazo grande para rematarla
        int crownShot = g_iWCrShot[witch];
        int chipTotal = chip + (g_iWCrDmg[witch][attacker] - crownShot);   // lo anterior al disparo final cuenta como chip
        if (chipTotal >= health) { chipTotal = health - 1; crownShot = 1; }
        else crownShot = health - chipTotal;
        if (crownShot >= g_cvDrawCrownMin.IntValue)
            SkAnnDrawCrown(attacker, crownShot, chipTotal);
    }
    SkWitchReset(witch);
}

// ----------------------------------------------------------------------------
//  Alarmas de auto
// ----------------------------------------------------------------------------
public void Event_SkCarAlarm(Event event, const char[] name, bool dontBroadcast)
{
    g_fLastCarAlarm = GetGameTime();
}

public void Hook_CarSpawn(int entity)
{
    if (!IsValidEntity(entity) || g_smCars == null) return;
    char target[48];
    GetEntPropString(entity, Prop_Data, "m_iName", target, sizeof target);
    g_smCars.SetValue(target, entity);
    if (entity < sizeof(g_iCarSurv)) { g_iCarSurv[entity] = 0; g_bCarAnn[entity] = false; }
}

public void Hook_GlassSpawn(int entity)
{
    // el vidrio esta emparentado a un auto: se enlazan por el nombre
    if (!IsValidEntity(entity) || g_smCars == null || entity >= sizeof(g_iGlassCar)) return;
    char parent[48];
    GetEntPropString(entity, Prop_Data, "m_iParent", parent, sizeof parent);
    int car;
    if (g_smCars.GetValue(parent, car) && IsValidEntity(car)) g_iGlassCar[entity] = car;
}

void SkCarHit(int car, int attacker, int inflictor, float damage, int damagetype)
{
    if (!SkSurv(attacker) || car < 1 || car >= sizeof(g_iCarSurv)) return;
    CreateTimer(0.01, Timer_SkCheckAlarm, EntIndexToEntRef(car), TIMER_FLAG_NO_MAPCHANGE);
    g_iCarSurv[car] = attacker;

    if (damagetype & DMG_BLAST)
    {
        if (SkInf(inflictor) && GetEntProp(inflictor, Prop_Send, "m_zombieClass") == SK_ZC_BOOMER)
        {
            g_iAlarmReason[attacker] = SK_CA_BOOMER;
            g_iAlarmBoomer = inflictor;
        }
        else g_iAlarmReason[attacker] = SK_CA_EXPLOSION;
    }
    else if (damage == 0.0 && (damagetype & (DMG_CLUB | DMG_SLASH)) && !(damagetype & DMG_SLOWBURN))
        g_iAlarmReason[attacker] = SK_CA_TOUCHED;   // empujon
    else
        g_iAlarmReason[attacker] = SK_CA_HIT;
}

public Action Hook_CarDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    SkCarHit(victim, attacker, inflictor, damage, damagetype);
    return Plugin_Continue;
}

public Action Hook_GlassDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype)
{
    if (victim >= 0 && victim < sizeof(g_iGlassCar) && g_iGlassCar[victim] > 0 && IsValidEntity(g_iGlassCar[victim]))
        SkCarHit(g_iGlassCar[victim], attacker, inflictor, damage, damagetype);
    return Plugin_Continue;
}

public void Hook_CarTouch(int entity, int other)
{
    if (!SkSurv(other) || entity < 1 || entity >= sizeof(g_iCarSurv)) return;
    CreateTimer(0.01, Timer_SkCheckAlarm, EntIndexToEntRef(entity), TIMER_FLAG_NO_MAPCHANGE);
    g_iCarSurv[entity] = other;
    g_iAlarmReason[other] = SK_CA_TOUCHED;
}

public void Hook_GlassTouch(int entity, int other)
{
    if (!SkSurv(other) || entity < 0 || entity >= sizeof(g_iGlassCar)) return;
    int car = g_iGlassCar[entity];
    if (car < 1 || !IsValidEntity(car)) return;
    CreateTimer(0.01, Timer_SkCheckAlarm, EntIndexToEntRef(car), TIMER_FLAG_NO_MAPCHANGE);
    g_iCarSurv[car] = other;
    g_iAlarmReason[other] = SK_CA_TOUCHED;
}

public Action Timer_SkCheckAlarm(Handle timer, any ref)
{
    int car = EntRefToEntIndex(ref);
    if (car < 1 || car >= sizeof(g_iCarSurv)) return Plugin_Stop;

    // la alarma sono justo despues del golpe/toque: es la responsable
    if ((GetGameTime() - g_fLastCarAlarm) < SK_CARALARM_TIME && !g_bCarAnn[car])
    {
        g_bCarAnn[car] = true;
        int survivor = g_iCarSurv[car];
        g_iCarSurv[car] = 0;
        if (!SkSurv(survivor)) return Plugin_Stop;

        // ¿un especial lo ayudo? (boomer, charger que lo lleva, jockey, smoker)
        int infected = 0;
        if (g_iAlarmReason[survivor] == SK_CA_BOOMER) infected = g_iAlarmBoomer;
        else
        {
            int e = GetEntPropEnt(survivor, Prop_Send, "m_carryAttacker");
            if (!SkInf(e)) e = GetEntPropEnt(survivor, Prop_Send, "m_jockeyAttacker");
            if (!SkInf(e)) e = GetEntPropEnt(survivor, Prop_Send, "m_tongueOwner");
            if (SkInf(e)) infected = e;
        }
        SkAnnCarAlarm(survivor, infected, g_iAlarmReason[survivor]);
    }
    return Plugin_Stop;
}

// ============================================================================
//  ANUNCIOS (tema propio: ✦ ✚ ➜ ★ ▼ »)
// ============================================================================

// Nombre del especial segun ZoneMod: si lo controla un JUGADOR se dice "al hunter de Nombre";
// si es un BOT no se muestra nombre y se dice "a un hunter".
void SkAl(int inf, const char[] esp, char[] out, int max)
{
    if (SkInf(inf) && !IsFakeClient(inf))
    {
        char nm[96];
        NombreMostrar(inf, nm, sizeof nm);
        Format(out, max, "al %s de \x03%s\x01", esp, nm);
    }
    else Format(out, max, "a un %s", esp);
}

// tipo: 0 = escopeta/normal, 1 = melee, 2 = sniper/magnum (cabeza), 3 = granada. attacker -2 = en equipo
void SkAnnSkeet(int attacker, int victim, int tipo)
{
    if (attacker > 0) StAdd(attacker, (tipo == 1) ? ST_SKEETMELEE : ST_SKEET);   // el skeet en equipo no se le acredita a nadie
    if (!SkOn(SK_SKEET)) return;
    g_fSkillAnnT[victim] = GetGameTime();
    if (attacker == -2)
    {
        if (SkInf(victim) && !IsFakeClient(victim))
        {
            char vn[96]; NombreMostrar(victim, vn, sizeof vn);
            PrintToChatAll("\x04✦\x01 El hunter de \x03%s\x01 recibió un \x04skeet en equipo", vn);
        }
        else PrintToChatAll("\x04✦\x01 Un hunter recibió un \x04skeet en equipo");
        return;
    }
    if (!SkSurv(attacker) || !SkVisible(attacker)) return;
    char qn[96], fr[160], extra[24];
    NombreMostrar(attacker, qn, sizeof qn);
    SkAl(victim, "hunter", fr, sizeof fr);
    switch (tipo)
    {
        case 1:  strcopy(extra, sizeof extra, " de melee");
        case 2:  strcopy(extra, sizeof extra, " de headshot");
        case 3:  strcopy(extra, sizeof extra, " con granada");
        default: extra[0] = '\0';
    }
    PrintToChatAll("\x04✦ \x03%s\x01 le hizo \x04skeet%s\x01 %s", qn, extra, fr);
}

// el hunter murio en el aire pero sin completar el daño de skeet
void SkAnnHurtSkeet(int attacker, int victim, int damage, bool sinChip)
{
    StAdd(attacker, ST_SKEETHURT);
    if (!SkOn(SK_HURTSKEET) || !SkSurv(attacker) || !SkVisible(attacker)) return;
    g_fSkillAnnT[victim] = GetGameTime();
    char cola[80];
    if (sinChip) strcopy(cola, sizeof cola, " (¡Hubiera sido skeet si el hunter no estuviera herido!)");
    else cola[0] = '\0';
    if (SkInf(victim) && !IsFakeClient(victim))
    {
        char vn[96]; NombreMostrar(victim, vn, sizeof vn);
        PrintToChatAll("\x04✦\x01 El hunter de \x03%s\x01 no fue \x04skeet\x01 (\x05%d\x01 de daño).%s", vn, damage, cola);
    }
    else PrintToChatAll("\x04✦\x01 Un hunter no fue \x04skeet\x01 (\x05%d\x01 de daño).%s", damage, cola);
}

void SkAnnLevel(int attacker, int victim)
{
    StAdd(attacker, ST_LEVEL);
    if (!SkOn(SK_LEVEL) || !SkVisible(attacker)) return;
    g_fSkillAnnT[victim] = GetGameTime();
    char qn[96], fr[160];
    NombreMostrar(attacker, qn, sizeof qn);
    SkAl(victim, "charger", fr, sizeof fr);
    PrintToChatAll("\x04✦ \x03%s\x01 hizo \x04level\x01 %s", qn, fr);
}

void SkAnnLevelHurt(int attacker, int victim, int damage)
{
    StAdd(attacker, ST_LEVELHURT);
    if (!SkOn(SK_HURTLEVEL) || !SkVisible(attacker)) return;
    g_fSkillAnnT[victim] = GetGameTime();
    char qn[96], fr[160];
    NombreMostrar(attacker, qn, sizeof qn);
    SkAl(victim, "charger", fr, sizeof fr);
    PrintToChatAll("\x04✦ \x03%s\x01 hizo \x04level parcial\x01 %s (\x05%d\x01 de daño)", qn, fr, damage);
}

void SkAnnDeadstop(int attacker, int victim)
{
    StAdd(attacker, ST_DEADSTOP);
    if (!SkOn(SK_DEADSTOP) || !SkVisible(attacker)) return;
    char qn[96], fr[160];
    NombreMostrar(attacker, qn, sizeof qn);
    SkAl(victim, "hunter", fr, sizeof fr);
    PrintToChatAll("\x04✦ \x03%s\x01 hizo \x04%s\x01 %s", qn, "deadstop", fr);
}

void SkAnnShove(int attacker, int victim)
{
    StAdd(attacker, ST_SHOVE);
    if (!SkOn(SK_SHOVE) || !SkVisible(attacker)) return;
    char qn[96];
    NombreMostrar(attacker, qn, sizeof qn);
    if (SkInf(victim) && !IsFakeClient(victim))
    {
        char vn[96]; NombreMostrar(victim, vn, sizeof vn);
        PrintToChatAll("\x04✦ \x03%s\x01 empujó a \x03%s", qn, vn);
    }
    else PrintToChatAll("\x04✦ \x03%s\x01 empujó a un especial", qn);
}

// el pop solo se cuenta; el aviso es el de "eliminó al Boomer en X s" (kill rápido)
void SkAnnPop(int attacker)
{
    StAdd(attacker, ST_POP);
}

// (ZoneMod no anuncia esto: viene apagado por defecto)
void SkAnnVomit(int boomer, int n)
{
    if (!SkOn(SK_VOMIT) || !SkInf(boomer)) return;
    char bn[96]; NombreMostrar(boomer, bn, sizeof bn);
    PrintToChatAll("\x04✦ \x03%s\x01 vomitó a \x05%d\x01 supervivientes", bn, n);
}

void SkAnnCrown(int attacker, int damage)
{
    StAdd(attacker, ST_CROWN);
    if (!SkOn(SK_CROWN) || !SkVisible(attacker)) return;
    // el desglose de la Witch ya dice "coronada por X": no repetir el mensaje
    if (g_cvWitch.BoolValue) return;
    char qn[96]; NombreMostrar(attacker, qn, sizeof qn);
    PrintToChatAll("\x04✦ \x03%s\x01 coronó a la \x04Witch\x01 (\x05%d\x01 de daño)", qn, damage);
}

void SkAnnDrawCrown(int attacker, int damage, int chip)
{
    StAdd(attacker, ST_CROWNHURT);
    if (!SkOn(SK_DRAWCROWN) || !SkVisible(attacker)) return;
    if (g_cvWitch.BoolValue) return;   // el desglose de la Witch ya lo muestra
    char qn[96]; NombreMostrar(attacker, qn, sizeof qn);
    PrintToChatAll("\x04✦ \x03%s\x01 hizo \x04%s\x01 a la Witch (\x05%d\x01 de daño, \x05%d\x01 de chip)", qn, "draw crown", damage, chip);
}

// (ZoneMod no anuncia esto: viene apagado por defecto)
void SkAnnRockEaten(int tank, int victim)
{
    if (!SkOn(SK_ROCKEATEN) || !SkSurv(victim) || !SkVisible(victim)) return;
    char vn[96];
    NombreMostrar(victim, vn, sizeof vn);
    if (SkInf(tank) && !IsFakeClient(tank))
    {
        char tn[96]; NombreMostrar(tank, tn, sizeof tn);
        PrintToChatAll("\x04▼ \x03%s\x01 se comió la \x04roca\x01 del Tank de \x03%s", vn, tn);
    }
    else PrintToChatAll("\x04▼ \x03%s\x01 se comió una \x04roca\x01 del Tank", vn);
}

void SkAnnHunterDP(int hunter, int victim, int dmg, float height)
{
    StAdd(hunter, ST_HUNTERDP);
    if (!SkOn(SK_HUNTERDP)) return;
    char vn[96]; NombreMostrar(victim, vn, sizeof vn);
    if (!IsFakeClient(hunter))
    {
        char hn[96]; NombreMostrar(hunter, hn, sizeof hn);
        PrintToChatAll("\x04✦ \x03%s\x01 hizo un \x04high pounce\x01 sobre \x03%s\x01 (\x05%d\x01 de daño, altura \x05%d\x01)", hn, vn, dmg, RoundFloat(height));
    }
    else PrintToChatAll("\x04✦\x01 Un hunter hizo un \x04high pounce\x01 sobre \x03%s\x01 (\x05%d\x01 de daño, altura \x05%d\x01)", vn, dmg, RoundFloat(height));
}

void SkAnnJockeyDP(int jockey, int victim, float height)
{
    StAdd(jockey, ST_JOCKEYDP);
    if (!SkOn(SK_JOCKEYDP)) return;
    char vn[96]; NombreMostrar(victim, vn, sizeof vn);
    if (!IsFakeClient(jockey))
    {
        char jn[96]; NombreMostrar(jockey, jn, sizeof jn);
        PrintToChatAll("\x04✦ \x03%s\x01 hizo un \x04high pounce\x01 sobre \x03%s\x01 (altura \x05%d\x01)", jn, vn, RoundFloat(height));
    }
    else PrintToChatAll("\x04✦\x01 Un jockey hizo un \x04high pounce\x01 sobre \x03%s\x01 (altura \x05%d\x01)", vn, RoundFloat(height));
}

void SkAnnDeathCharge(int charger, int victim, float height, bool carried)
{
    if (height >= g_cvDCAlt.FloatValue) StAdd(charger, ST_DEATHCHARGE);
    if (!SkOn(SK_DEATHCHARGE) || height < g_cvDCAlt.FloatValue || !SkInf(charger)) return;
    char vn[96]; NombreMostrar(victim, vn, sizeof vn);
    if (!IsFakeClient(charger))
    {
        char cn[96]; NombreMostrar(charger, cn, sizeof cn);
        PrintToChatAll("\x04✦ \x03%s\x01 hizo un \x04%s\x01 a \x03%s\x01%s (altura \x05%d\x01)",
            cn, "death charge", vn, carried ? "" : " por bowling", RoundFloat(height));
    }
    else PrintToChatAll("\x04✦\x01 Un charger hizo un \x04%s\x01 a \x03%s\x01%s (altura \x05%d\x01)",
            "death charge", vn, carried ? "" : " por bowling", RoundFloat(height));
}

void SkAnnBhop(int client, int streak, float maxVel)
{
    if (!SkOn(SK_BHOP) || streak < g_cvBhopMin.IntValue || !IsClientInGame(client) || IsFakeClient(client)) return;
    PrintToChat(client, "\x04➜ Hiciste \x05%d\x01 bunnyhop%s seguidos (\x04velocidad máx\x01: \x05%.1f\x01)", streak, (streak > 1) ? "s" : "", maxVel);
}

void SkAnnCarAlarm(int survivor, int infected, int reason)
{
    // igual que ZoneMod: solo se anuncia si el superviviente es un jugador
    if (!SkOn(SK_CARALARM) || IsFakeClient(survivor)) return;
    char sn[96];
    NombreMostrar(survivor, sn, sizeof sn);
    bool inf = SkInf(infected);
    bool infHumano = inf && !IsFakeClient(infected);

    switch (reason)
    {
        case SK_CA_HIT:
            PrintToChatAll("\x04▼ \x03%s\x01 activó una \x04%s\x01 con un golpe", sn, "alarma");
        case SK_CA_TOUCHED:
        {
            if (infHumano)
            {
                char inn[96]; NombreMostrar(infected, inn, sizeof inn);
                PrintToChatAll("\x04▼ \x03%s\x01 hizo que \x03%s\x01 activara una \x04%s", inn, sn, "alarma");
            }
            else if (inf)
            {
                char cls[16];
                switch (GetEntProp(infected, Prop_Send, "m_zombieClass"))
                {
                    case SK_ZC_SMOKER:  strcopy(cls, sizeof cls, "smoker");
                    case SK_ZC_HUNTER:  strcopy(cls, sizeof cls, "hunter");
                    case SK_ZC_JOCKEY:  strcopy(cls, sizeof cls, "jockey");
                    case SK_ZC_CHARGER: strcopy(cls, sizeof cls, "charger");
                    default:            strcopy(cls, sizeof cls, "infectado bot");
                }
                PrintToChatAll("\x04▼\x01 Un %s hizo que \x03%s\x01 activara una \x04%s", cls, sn, "alarma");
            }
            else PrintToChatAll("\x04▼ \x03%s\x01 tocó un auto con \x04%s", sn, "alarma");
        }
        case SK_CA_EXPLOSION:
            PrintToChatAll("\x04▼ \x03%s\x01 activó una \x04%s\x01 con una explosión", sn, "alarma");
        case SK_CA_BOOMER:
        {
            if (infHumano)
            {
                char inn2[96]; NombreMostrar(infected, inn2, sizeof inn2);
                PrintToChatAll("\x04▼ \x03%s\x01 activó una \x04%s\x01 al matar al boomer de \x03%s", sn, "alarma", inn2);
            }
            else PrintToChatAll("\x04▼ \x03%s\x01 activó una \x04%s\x01 al dispararle a un boomer", sn, "alarma");
        }
        default:
            PrintToChatAll("\x04▼ \x03%s\x01 activó una \x04%s", sn, "alarma");
    }
}

// ============================================================================
//  ESTADISTICAS DE SKILLS POR JUGADOR (los mismos datos que l4d2_playstats de ZoneMod)
// ============================================================================

void StAdd(int c, int k, int n = 1)
{
    if (c >= 1 && c <= MaxClients && g_cvActivo.BoolValue) g_iSt[c][k] += n;
}

void EnviarConsola(int target, const char[] msg)
{
    if (target == 0)
    {
        for (int i = 1; i <= MaxClients; i++)
            if (IsClientInGame(i) && !IsFakeClient(i)) PrintToConsole(i, "%s", msg);
    }
    else if (target >= 1 && target <= MaxClients && IsClientInGame(target))
        PrintToConsole(target, "%s", msg);
}


// ---------------------------------------------------------------------------
//  Tablas de consola (mismo estilo y columnas que l4d2_playstats de ZoneMod)
// ---------------------------------------------------------------------------
void TblNombre(int c, char[] out, int max)
{
    char raw[64];
    GetClientName(c, raw, sizeof raw);
    strcopy(out, max, raw);   // se recorta a 20 caracteres
}

// Tablas de la ronda: MVP (especiales/comunes/FF), skills, extras e infectados. Ordenado por daño a especiales.
void ConsolaStats(int target)
{
    int ord[MAXPLAYERS+1], n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (ContarEnStats(i) && GetClientTeam(i) == 2) ord[n++] = i;
    for (int i = 0; i < n - 1; i++)
        for (int j = 0; j < n - 1 - i; j++)
            if (g_iSIDano[ord[j]] < g_iSIDano[ord[j+1]]) { int t = ord[j]; ord[j] = ord[j+1]; ord[j+1] = t; }

    int totSI = 0, totCI = 0;
    for (int x = 0; x < n; x++) { totSI += g_iSIDano[ord[x]]; totCI += g_iComunes[ord[x]]; }

    char l[300], nm[21], c1[32], c2[32], c3[32];

    // --- MVP ---
    EnviarConsola(target, " ");
    EnviarConsola(target, "|------------------------------------------------------------------------------------------------|");
    EnviarConsola(target, "| Survivor MVP Stats -- This Round                                                               |");
    EnviarConsola(target, "|----------------------|----------------------|----------------|--------|--------|-------|-------|");
    EnviarConsola(target, "| Name                 | Specials kills/dmg   | Commons        | Tank   | Witch  | FF    | Rcvd  |");
    EnviarConsola(target, "|----------------------|----------------------|----------------|--------|--------|-------|-------|");
    for (int x = 0; x < n; x++)
    {
        int c = ord[x];
        TblNombre(c, nm, sizeof nm);
        Format(c1, sizeof c1, "%4d %8d  %4d%%", g_iKills[c], g_iSIDano[c], Pct(g_iSIDano[c], totSI));
        Format(c2, sizeof c2, "%7d  %4d%%", g_iComunes[c], Pct(g_iComunes[c], totCI));
        Format(l, sizeof l, "| %20s | %20s | %14s | %6d | %6d | %5d | %5d |", nm, c1, c2,
            g_iSt[c][ST_TANKDMG], g_iSt[c][ST_WITCHDMG], g_iFF[c], g_iSt[c][ST_FFTAKEN]);
        EnviarConsola(target, l);
    }
    if (n == 0) EnviarConsola(target, "| (nothing to display)                                                                           |");
    EnviarConsola(target, "|----------------------|----------------------|----------------|--------|--------|-------|-------|");

    // --- Skills ---
    EnviarConsola(target, " ");
    EnviarConsola(target, "|---------------------------------------------------------------------------------------------------|");
    EnviarConsola(target, "| Special -- This Round     skts(full/hurt/melee); lvl(full/hurt); crwn(full/draw)                  |");
    EnviarConsola(target, "|----------------------|------------------|-----------|-----------|------|-------------|------------|");
    EnviarConsola(target, "| Name                 | Skeets fl/ht/ml  | Levels    | Crowns    | Pops | Cuts / Self | DSs / M2s  |");
    EnviarConsola(target, "|----------------------|------------------|-----------|-----------|------|-------------|------------|");
    for (int x = 0; x < n; x++)
    {
        int c = ord[x];
        TblNombre(c, nm, sizeof nm);
        Format(c1, sizeof c1, "%d/%d/%d", g_iSt[c][ST_SKEET], g_iSt[c][ST_SKEETHURT], g_iSt[c][ST_SKEETMELEE]);
        Format(c2, sizeof c2, "%d/%d", g_iSt[c][ST_LEVEL], g_iSt[c][ST_LEVELHURT]);
        Format(c3, sizeof c3, "%d/%d", g_iSt[c][ST_CROWN], g_iSt[c][ST_CROWNHURT]);
        char c4[32], c5[32];
        Format(c4, sizeof c4, "%d / %d", g_iSt[c][ST_TONGUECUT], g_iSt[c][ST_SELFCLEAR]);
        Format(c5, sizeof c5, "%d / %d", g_iSt[c][ST_DEADSTOP], g_iSt[c][ST_SHOVE]);
        Format(l, sizeof l, "| %20s | %16s | %9s | %9s | %4d | %11s | %10s |", nm, c1, c2, c3, g_iSt[c][ST_POP], c4, c5);
        EnviarConsola(target, l);
    }
    if (n == 0) EnviarConsola(target, "| (nothing to display)                                                                              |");
    EnviarConsola(target, "|----------------------|------------------|-----------|-----------|------|-------------|------------|");

    // --- Extras ---
    EnviarConsola(target, " ");
    EnviarConsola(target, "|-------------------------------------------------------------|");
    EnviarConsola(target, "| Extras -- This Round                                        |");
    EnviarConsola(target, "|----------------------|--------------|-------|-------|-------|");
    EnviarConsola(target, "| Name                 | Rocks sk/eat | Saves | Incap | Died  |");
    EnviarConsola(target, "|----------------------|--------------|-------|-------|-------|");
    for (int x = 0; x < n; x++)
    {
        int c = ord[x];
        TblNombre(c, nm, sizeof nm);
        Format(c1, sizeof c1, "%d / %d", g_iSt[c][ST_ROCKSKEET], g_iSt[c][ST_ROCKEAT]);
        Format(l, sizeof l, "| %20s | %12s | %5d | %5d | %5d |", nm, c1, g_iSt[c][ST_CLEAR], g_iSt[c][ST_INCAP], g_iSt[c][ST_DIED]);
        EnviarConsola(target, l);
    }
    if (n == 0) EnviarConsola(target, "| (nothing to display)                                        |");
    EnviarConsola(target, "|----------------------|--------------|-------|-------|-------|");

    // --- Infectados (solo si alguien hizo high pounce / death charge) ---
    bool cab = false;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != 3) continue;
        if (g_iSt[i][ST_HUNTERDP] + g_iSt[i][ST_JOCKEYDP] + g_iSt[i][ST_DEATHCHARGE] <= 0) continue;
        if (!cab)
        {
        EnviarConsola(target, " ");
        EnviarConsola(target, "|-------------------------------------------------------------|");
        EnviarConsola(target, "| Infected -- This Round                                      |");
        EnviarConsola(target, "|----------------------|-----------|-----------|--------------|");
        EnviarConsola(target, "| Name                 | Hunter HP | Jockey HP | Death charge |");
        EnviarConsola(target, "|----------------------|-----------|-----------|--------------|");
            cab = true;
        }
        TblNombre(i, nm, sizeof nm);
        Format(l, sizeof l, "| %20s | %9d | %9d | %12d |", nm, g_iSt[i][ST_HUNTERDP], g_iSt[i][ST_JOCKEYDP], g_iSt[i][ST_DEATHCHARGE]);
        EnviarConsola(target, l);
    }
    if (cab)
    {
        EnviarConsola(target, "|----------------------|-----------|-----------|--------------|");
    }
    EnviarConsola(target, " ");
}

public Action Cmd_Skills(int client, int args)
{
    if (client < 1) return Plugin_Handled;
    ConsolaStats(client);
    PrintToChat(client, "\x04»\x01 Las stats de skills de la ronda estan en tu consola (tecla \x04~\x01).");
    return Plugin_Handled;
}

// ============================================================================
//  RESUMEN DE LA CAMPAÑA (acumula todas las rondas y se muestra al final, ordenado)
// ============================================================================
enum
{
    CP_SI, CP_KILLS, CP_CI, CP_SKEET, CP_LEVEL, CP_CROWN, CP_POP, CP_CUT, CP_DS, CP_ROCK, CP_CLEAR,
    CP_FF, CP_TANK, CP_WITCH, CP_INCAP, CP_DIED, CP_SKILLS,
    CP_COUNT
};
#define CAMP_MAX 64
int  g_iCamp[CAMP_MAX][CP_COUNT];
char g_sCampId[CAMP_MAX][40];
char g_sCampNom[CAMP_MAX][48];
int  g_iCampN;
int  g_iCampRondas;
bool g_bCampMostrada;

void CampReset()
{
    for (int i = 0; i < CAMP_MAX; i++)
        for (int k = 0; k < CP_COUNT; k++) g_iCamp[i][k] = 0;
    g_iCampN = 0;
    g_iCampRondas = 0;
}

// al empezar el mapa: si es el primer capitulo de una campaña, se parte de cero
void CampMapStart()
{
    char mapa[64];
    GetCurrentMap(mapa, sizeof mapa);
    if (StrContains(mapa, "m1_", false) != -1) CampReset();
    g_bCampMostrada = false;
}

int CampBuscar(int c)
{
    char id[40];
    if (IsFakeClient(c)) { GetClientName(c, id, sizeof id); Format(id, sizeof id, "BOT:%s", id); }
    else if (!GetClientAuthId(c, AuthId_Steam2, id, sizeof id)) GetClientName(c, id, sizeof id);
    for (int i = 0; i < g_iCampN; i++)
        if (StrEqual(g_sCampId[i], id)) return i;
    if (g_iCampN >= CAMP_MAX) return -1;
    int n = g_iCampN++;
    strcopy(g_sCampId[n], sizeof g_sCampId[], id);
    return n;
}

// suma lo de la ronda que termina (se llama justo antes de reiniciar los contadores)
void CampAcumular()
{
    bool alguien = false;
    for (int c = 1; c <= MaxClients; c++)
    {
        if (!ContarEnStats(c)) continue;
        int tot = g_iSIDano[c] + g_iKills[c] + g_iComunes[c];
        for (int k = 0; k < ST_COUNT; k++) tot += g_iSt[c][k];
        if (tot <= 0 && g_iFF[c] <= 0) continue;
        int n = CampBuscar(c);
        if (n < 0) continue;
        GetClientName(c, g_sCampNom[n], sizeof g_sCampNom[]);
        g_iCamp[n][CP_SI]    += g_iSIDano[c];
        g_iCamp[n][CP_KILLS] += g_iKills[c];
        g_iCamp[n][CP_CI]    += g_iComunes[c];
        g_iCamp[n][CP_SKEET] += g_iSt[c][ST_SKEET] + g_iSt[c][ST_SKEETMELEE];
        g_iCamp[n][CP_LEVEL] += g_iSt[c][ST_LEVEL];
        g_iCamp[n][CP_CROWN] += g_iSt[c][ST_CROWN] + g_iSt[c][ST_CROWNHURT];
        g_iCamp[n][CP_POP]   += g_iSt[c][ST_POP];
        g_iCamp[n][CP_CUT]   += g_iSt[c][ST_TONGUECUT];
        g_iCamp[n][CP_DS]    += g_iSt[c][ST_DEADSTOP];
        g_iCamp[n][CP_ROCK]  += g_iSt[c][ST_ROCKSKEET];
        g_iCamp[n][CP_CLEAR] += g_iSt[c][ST_CLEAR];
        g_iCamp[n][CP_FF]    += g_iFF[c];
        g_iCamp[n][CP_TANK]  += g_iSt[c][ST_TANKDMG];
        g_iCamp[n][CP_WITCH] += g_iSt[c][ST_WITCHDMG];
        g_iCamp[n][CP_INCAP] += g_iSt[c][ST_INCAP];
        g_iCamp[n][CP_DIED]  += g_iSt[c][ST_DIED];
        g_iCamp[n][CP_SKILLS] = g_iCamp[n][CP_SKEET] + g_iCamp[n][CP_LEVEL] + g_iCamp[n][CP_CROWN] + g_iCamp[n][CP_POP]
                              + g_iCamp[n][CP_CUT] + g_iCamp[n][CP_DS] + g_iCamp[n][CP_ROCK] + g_iCamp[n][CP_CLEAR];
        alguien = true;
    }
    if (alguien) g_iCampRondas++;
}


// Resumen de la campaña: mismas cajas, ordenado del que mas skills hizo al que menos (empate: mas daño a especiales)
void CampMostrar(int target)
{
    int ord[CAMP_MAX];
    for (int i = 0; i < g_iCampN; i++) ord[i] = i;
    for (int i = 0; i < g_iCampN - 1; i++)
        for (int j = 0; j < g_iCampN - 1 - i; j++)
        {
            int a = ord[j], b = ord[j+1];
            if (g_iCamp[a][CP_SKILLS] < g_iCamp[b][CP_SKILLS]
                || (g_iCamp[a][CP_SKILLS] == g_iCamp[b][CP_SKILLS] && g_iCamp[a][CP_SI] < g_iCamp[b][CP_SI]))
            { ord[j] = b; ord[j+1] = a; }
        }

    char l[300], nm[24], pre[48];
    EnviarConsola(target, " ");
    Format(l, sizeof l, "=== CAMPAIGN SUMMARY (%d rounds) ===", g_iCampRondas);
    EnviarConsola(target, l);
    EnviarConsola(target, "|---------------------------------------------------------------------------------|");
    EnviarConsola(target, "| Campaign Stats -- ALL Rounds (sorted by skills)                                 |");
    EnviarConsola(target, "|----------------------|--------|---------|-------|-------|-------|-------|-------|");
    EnviarConsola(target, "| Name                 | Skills | SI dmg  | Kills | CI    | FF    | Incap | Died  |");
    EnviarConsola(target, "|----------------------|--------|---------|-------|-------|-------|-------|-------|");
    for (int r = 0; r < g_iCampN; r++)
    {
        int n = ord[r];
        Format(pre, sizeof pre, "%d. %s", r + 1, g_sCampNom[n]);
        strcopy(nm, 21, pre);
        Format(l, sizeof l, "| %20s | %6d | %7d | %5d | %5d | %5d | %5d | %5d |", nm, g_iCamp[n][CP_SKILLS], g_iCamp[n][CP_SI],
            g_iCamp[n][CP_KILLS], g_iCamp[n][CP_CI], g_iCamp[n][CP_FF], g_iCamp[n][CP_INCAP], g_iCamp[n][CP_DIED]);
        EnviarConsola(target, l);
    }
    if (g_iCampN == 0) EnviarConsola(target, "| (nothing to display)                                                            |");
    EnviarConsola(target, "|----------------------|--------|---------|-------|-------|-------|-------|-------|");
    EnviarConsola(target, " ");
    EnviarConsola(target, "|---------------------------------------------------------------------------------------|");
    EnviarConsola(target, "| Campaign Skills -- ALL Rounds     (sorted by skills)                                  |");
    EnviarConsola(target, "|----------------------|--------|--------|--------|------|-------|------|-------|-------|");
    EnviarConsola(target, "| Name                 | Skeets | Levels | Crowns | Pops | Cuts  | DS   | Rocks | Saves |");
    EnviarConsola(target, "|----------------------|--------|--------|--------|------|-------|------|-------|-------|");
    for (int r = 0; r < g_iCampN; r++)
    {
        int n = ord[r];
        Format(pre, sizeof pre, "%d. %s", r + 1, g_sCampNom[n]);
        strcopy(nm, 21, pre);
        Format(l, sizeof l, "| %20s | %6d | %6d | %6d | %4d | %5d | %4d | %5d | %5d |", nm, g_iCamp[n][CP_SKEET], g_iCamp[n][CP_LEVEL],
            g_iCamp[n][CP_CROWN], g_iCamp[n][CP_POP], g_iCamp[n][CP_CUT], g_iCamp[n][CP_DS], g_iCamp[n][CP_ROCK], g_iCamp[n][CP_CLEAR]);
        EnviarConsola(target, l);
    }
    if (g_iCampN == 0) EnviarConsola(target, "| (nothing to display)                                                                  |");
    EnviarConsola(target, "|----------------------|--------|--------|--------|------|-------|------|-------|-------|");
    EnviarConsola(target, "Skills = skeets + levels + crowns + pops + cuts + deadstops + rock skeets + saves");
    EnviarConsola(target, " ");
}

public Action Cmd_Campana(int client, int args)
{
    if (client < 1) return Plugin_Handled;
    CampMostrar(client);
    PrintToChat(client, "\x04»\x01 El resumen de la campaña está en tu consola (tecla \x04~\x01).");
    return Plugin_Handled;
}

// fin de la campaña: se muestra a todos y se empieza de cero
public void Event_CampFin(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvActivo.BoolValue || g_bCampMostrada) return;
    if (StrEqual(name, "finale_win"))
    {
        // en versus el final de la campaña lo marca versus_match_finished (finale_win sale en cada mitad)
        ConVar gm = FindConVar("mp_gamemode");
        char modo[32];
        if (gm != null) gm.GetString(modo, sizeof modo);
        if (StrContains(modo, "versus", false) != -1) return;
    }
    g_bCampMostrada = true;
    CreateTimer(2.0, Timer_CampFin, _, TIMER_FLAG_NO_MAPCHANGE);   // deja que se sume la ultima ronda
}

public Action Timer_CampFin(Handle timer)
{
    CampMostrar(0);
    CampReset();
    return Plugin_Stop;
}
