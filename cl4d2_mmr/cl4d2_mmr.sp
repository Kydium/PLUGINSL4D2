/**
 * L4D2 MMR System - ClubCampestre
 * Version 32.0.0 - SIMPLE + HUD (panel estilo ZoneMod) + castigo por salida y abandono
 *
 * v32 - Registro de la campaña:
 *   - Cada mitad que termina, se anota en que equipo (A/B) jugo cada uno.
 *   - Resultado por partes si te cambiaron de equipo a mitad de campaña.
 *   - El que se va y no vuelve: derrota + castigo extra (interno, no sale en el panel).
 *   - Si un equipo entero se va (3 min sin nadie): el otro gana por abandono (50 %).
 *   - Si se van los dos equipos: anulada, sin castigos.
 *
 * Funcionamiento:
 *   Al terminar la campaña (2da mitad del mapa final), se mira quien gano
 *   (marcador de campaña). Cada jugador que jugo al menos 1 mitad:
 *     - si esta en el server: suma/resta segun las mitades que jugo en cada equipo
 *     - si se fue y no volvio: derrota + castigo (sm_mmr_castigo_salida)
 *   Pasarse a espectador NO es irse: se le cuenta con su equipo.
 *   - Sin grupos ni rosters fijos: se anota en que equipo juega cada uno en cada mitad.
 *   - Si en toda la campaña hubo como maximo 1 jugador por lado -> tabla 1v1.
 *   - sm_mmr_status muestra el registro (mitades por equipo, quien esta FUERA).
 *
 * Opciones v32 (cfg/sourcemod/l4d2_mmr_system.cfg):
 *   sm_mmr_castigo_salida  20   SR extra que pierde el que se va (ademas de la derrota)
 *   sm_mmr_abandono_pct    50   % de una victoria para el equipo que se quedo
 *   sm_mmr_abandono_espera 180  segundos sin nadie para declarar abandono
 *   sm_mmr_min_mitades     1    mitades minimas para contar
 *
 * HUD (panel a la izquierda-centro, cada jugador ve el suyo, sin chat):
 *   - Fin de campaña: VICTORIA / DERROTA con los 2 equipos (tu linea en naranja).
 *   - !mmr, !top, !mmr_jugador, !mmr1v1, !top1v1 salen en el panel.
 *   - Al iniciar la ronda: Top 10 (10 s) y luego tu SR (10 s), una sola vez.
 *     En pausa no se dibuja nada (solo el menu de pausa); si la pausa cae en
 *     medio, al reanudar empieza otra vez desde el Top 10.
 *     No se activa si esta cargado readyup (su panel y este se pisarian).
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION  "32.0.0"

#define DEFAULT_K_FACTOR    "80"
#define DEFAULT_ENABLED     "1"
#define DEFAULT_DEBUG       "0"
#define DEFAULT_MMR         500

// Umbrales de RANGOS por MMR (iguales a los del MOTD)
#define RANGO_LEYENDA       10000
#define RANGO_MAESTRO       8500
#define RANGO_DIAMANTE      7000
#define RANGO_PLATINO       5200
#define RANGO_ORO           3600
#define RANGO_PLATA         2200
#define RANGO_BRONCE        1000

#define TOP_LIMITE          10

// HUD (panel)
#define HUD_MAX_LINEAS      24
#define HUD_LARGO_LINEA     128
#define HUD_NOMBRE_MAX      16      // caracteres maximos del nombre (se recorta con "..")

#define TEAM_SURVIVORS  2
#define TEAM_INFECTED   3

public Plugin myinfo =
{
    name        = "L4D2 SR System (simple)",
    author      = "ClubCampestre",
    description = "Al terminar la campaña: gana suma SR, pierde resta SR",
    version     = PLUGIN_VERSION,
    url         = ""
};

Database g_DB = null;

// Pausa: cl4d2_pausa (nuestro) o pause.sp de ZoneMod. Opcionales.
native bool CL4D2_EstaEnPausa();
native bool IsInPause();

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    MarkNativeAsOptional("CL4D2_EstaEnPausa");
    MarkNativeAsOptional("IsInPause");
    return APLRes_Success;
}

// true si el juego esta en pausa (para no dibujar paneles encima del menu de pausa)
bool EnPausa()
{
    if (GetFeatureStatus(FeatureType_Native, "CL4D2_EstaEnPausa") == FeatureStatus_Available && CL4D2_EstaEnPausa())
        return true;
    if (GetFeatureStatus(FeatureType_Native, "IsInPause") == FeatureStatus_Available && IsInPause())
        return true;
    return false;
}

ConVar g_cvEnabled;
ConVar g_cvKFactor;
ConVar g_cvDebugMode;
ConVar g_cvWebScript;

int  g_iMMR[MAXPLAYERS + 1];
int  g_iWins[MAXPLAYERS + 1];
int  g_iLosses[MAXPLAYERS + 1];
bool g_bLoaded[MAXPLAYERS + 1];

// Tabla destino al guardar (se activa solo mientras se procesa un 1v1)
bool g_bModoEs1v1 = false;

// Estado del mapa actual
int   g_iMitadesTerminadas = 0;   // 0 = jugando mitad 1, 1 = jugando mitad 2
int   g_iSurvIdxMitad1     = -1;  // equipo de campaña (0/1) que fue survivor en la mitad 1
int   g_iScoreInicio[2];          // scores de campaña al empezar la mitad actual
bool  g_bScoreInicioValido = false;
bool  g_bProcesado         = false;
float g_fUltimoFinRonda    = 0.0;

// ─── Registro de la campaña (v32) ───
#define MAX_REG 64
int    g_iRegCnt = 0;
char   g_sRegSteam[MAX_REG][32];
char   g_sRegNombre[MAX_REG][MAX_NAME_LENGTH];
int    g_iRegMitades[MAX_REG][2];      // mitades jugadas en el equipo A / B
int    g_iRegUltimoEquipo[MAX_REG];    // ultimo equipo en que se le vio (0/1, -1 = ninguno)
int    g_iMitadesTotales  = 0;         // mitades terminadas en esta campaña
int    g_iMaxPorLado      = 0;         // max de humanos por lado (para detectar 1v1)
bool   g_bCampaniaCerrada = false;     // ya se proceso (final, abandono o sin jugadores)
int    g_iSegVacio[2];                 // segundos seguidos que el equipo A/B lleva sin nadie
float  g_fMapaInicio      = 0.0;

ConVar g_cvCastigoSalida;
ConVar g_cvAbandonoPct;
ConVar g_cvAbandonoEspera;
ConVar g_cvMinMitades;

// ─── HUD (panel por jugador) ───
ConVar g_cvHudPad;
ConVar g_cvHudRotar;
ConVar g_cvHudSegFin;
ConVar g_cvHudSegCmd;
ConVar g_cvHudSegRotar;
char   g_sHudLinea[MAXPLAYERS + 1][HUD_MAX_LINEAS][HUD_LARGO_LINEA];
bool   g_bHudNaranja[MAXPLAYERS + 1][HUD_MAX_LINEAS];
int    g_iHudLineas[MAXPLAYERS + 1];
int    g_iHudResta[MAXPLAYERS + 1];
bool   g_bHudSinItems[MAXPLAYERS + 1];   // naranjas dibujadas en blanco (no bloquea teclas 1-9)
Handle g_hHudTimer[MAXPLAYERS + 1];

// Resultado de la ultima campaña (para armar el panel de fin)
int    g_iFinCnt[2];
int    g_iFinCli[2][MAXPLAYERS + 1];
int    g_iFinDiff[2][MAXPLAYERS + 1];
int    g_iFinMMR[2][MAXPLAYERS + 1];
char   g_sFinNom[2][MAXPLAYERS + 1][MAX_NAME_LENGTH];
int    g_iFinGanador = -1;
bool   g_bFin1v1 = false;
bool   g_bFinAbandono = false;

// Cache del top 10 (para !top y la rotacion)
int    g_iTopCnt = 0;
char   g_sTopNom[TOP_LIMITE][MAX_NAME_LENGTH];
char   g_sTopSteam[TOP_LIMITE][32];
int    g_iTopMMR[TOP_LIMITE];
int    g_iTopW[TOP_LIMITE];
int    g_iTopL[TOP_LIMITE];

// Puesto de cada jugador en el ranking (0 = desconocido)
int    g_iRank[MAXPLAYERS + 1];

// Rotacion en el refugio
Handle g_hRotar = null;
int    g_iRotarPaso = 0;     // 0 = Top 10, 1 = tu SR
int    g_iSecSeg    = 0;     // segundos que le quedan a la pantalla actual
bool   g_bSecReiniciar = false;   // mostrar desde el principio en el proximo segundo

public void OnPluginStart()
{
    g_cvEnabled   = CreateConVar("sm_mmr_enable", DEFAULT_ENABLED,  "Activa/desactiva el sistema SR", FCVAR_NOTIFY);
    g_cvKFactor   = CreateConVar("sm_mmr_k",      DEFAULT_K_FACTOR, "Factor K del calculo Elo", FCVAR_NOTIFY);
    g_cvDebugMode = CreateConVar("sm_mmr_debug",  DEFAULT_DEBUG,    "1 = cuenta aunque un equipo no tenga humanos (para probar solo)", FCVAR_NOTIFY);
    g_cvWebScript = CreateConVar("sm_mmr_web_script", "0", "1 = genera data/mmr_index.html al terminar la campaña", FCVAR_NOTIFY);
    g_cvHudPad    = CreateConVar("sm_mmr_hud_pad",   "4", "Espacios delante de las lineas blancas del panel (para alinear con las naranjas)", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvHudRotar  = CreateConVar("sm_mmr_hud_rotar", "1", "1 = al iniciar la ronda muestra el Top 10 y luego tu SR (una vez)", FCVAR_NOTIFY);
    g_cvHudSegFin   = CreateConVar("sm_mmr_hud_seg_fin",   "30", "Segundos que se ve el panel de fin de campaña", FCVAR_NOTIFY, true, 1.0, true, 300.0);
    g_cvHudSegCmd   = CreateConVar("sm_mmr_hud_seg_cmd",   "10", "Segundos que se ve !mmr, !top, !mmr_jugador, !mmr1v1, !top1v1", FCVAR_NOTIFY, true, 1.0, true, 300.0);
    g_cvHudSegRotar = CreateConVar("sm_mmr_hud_seg_inicio", "10", "Segundos de cada pantalla al iniciar la ronda (Top 10 y luego tu SR)", FCVAR_NOTIFY, true, 2.0, true, 60.0);

    g_cvCastigoSalida  = CreateConVar("sm_mmr_castigo_salida",  "20",  "SR extra que pierde el que se sale y no vuelve (ademas de la derrota)", FCVAR_NOTIFY, true, 0.0, true, 500.0);
    g_cvAbandonoPct    = CreateConVar("sm_mmr_abandono_pct",    "50",  "Porcentaje de una victoria normal que gana el equipo que se quedo si el otro abandona", FCVAR_NOTIFY, true, 0.0, true, 100.0);
    g_cvAbandonoEspera = CreateConVar("sm_mmr_abandono_espera", "180", "Segundos que un equipo debe estar sin nadie para declarar abandono", FCVAR_NOTIFY, true, 30.0, true, 1800.0);
    g_cvMinMitades     = CreateConVar("sm_mmr_min_mitades",     "1",   "Mitades minimas jugadas para contar en la campaña (y para el castigo por salida)", FCVAR_NOTIFY, true, 1.0, true, 20.0);

    AutoExecConfig(true, "l4d2_mmr_system");

    RegConsoleCmd("sm_mmr",            Cmd_MMR,         "Muestra tu SR, partidas y ranking global");
    RegConsoleCmd("sm_top",            Cmd_Top,         "Top 10 jugadores por SR");
    RegConsoleCmd("sm_mmr_jugador",    Cmd_MMRJugador,  "SR de otro jugador: sm_mmr_jugador <nombre>");
    RegConsoleCmd("sm_mmr1v1",         Cmd_MMR1v1,      "Muestra tu SR 1v1");
    RegConsoleCmd("sm_sr",             Cmd_MMR,         "Muestra tu SR, partidas y ranking global");
    RegConsoleCmd("sm_sr_jugador",     Cmd_MMRJugador,  "SR de otro jugador: sm_sr_jugador <nombre>");
    RegConsoleCmd("sm_sr1v1",          Cmd_MMR1v1,      "Muestra tu SR 1v1");
    RegConsoleCmd("sm_top1v1",         Cmd_Top1v1,      "Top 10 jugadores 1v1");

    RegAdminCmd("sm_setmmr",           Cmd_SetMMR,      ADMFLAG_GENERIC, "Ajusta SR: sm_setmmr <target> <cantidad>");
    RegAdminCmd("sm_resetmmr",         Cmd_ResetMMR,    ADMFLAG_GENERIC, "Resetea SR a 500: sm_resetmmr <target>");
    RegAdminCmd("sm_setmmr1v1",        Cmd_SetMMR1v1,   ADMFLAG_GENERIC, "Ajusta SR 1v1: sm_setmmr1v1 <target> <cantidad>");
    RegAdminCmd("sm_resetmmr1v1",      Cmd_ResetMMR1v1, ADMFLAG_GENERIC, "Resetea SR 1v1 a 500: sm_resetmmr1v1 <target>");
    RegAdminCmd("sm_mmr_reload",       Cmd_ReloadMMR,   ADMFLAG_GENERIC, "Recarga la DB y el SR de los jugadores");
    RegAdminCmd("sm_mmr_status",       Cmd_StatusMMR,   ADMFLAG_GENERIC, "Estado actual: equipos, puntaje y quien va ganando");
    RegAdminCmd("sm_mmr_web",          Cmd_WebGenerar,  ADMFLAG_GENERIC, "Genera el index.html ahora mismo");
    RegAdminCmd("sm_mmr_testhud",      Cmd_TestHud,     ADMFLAG_GENERIC, "Muestra el panel de fin de campaña con los jugadores actuales (datos de prueba, no guarda)");
    RegAdminCmd("sm_mmr_rotar",        Cmd_Rotar,       ADMFLAG_GENERIC, "Muestra a mano la secuencia Top 10 -> tu SR (o la quita)");

    HookEvent("round_start",            Event_RoundStart,     EventHookMode_PostNoCopy);
    HookEvent("player_left_start_area", Event_SalidaSaferoom, EventHookMode_PostNoCopy);
    HookEvent("round_end",              Event_RoundEnd,       EventHookMode_PostNoCopy);
}

public void OnAllPluginsLoaded()
{
    InitDatabase();
}

public void OnMapStart()
{
    g_iMitadesTerminadas = 0;
    g_iSurvIdxMitad1     = -1;
    g_bScoreInicioValido = false;
    g_bProcesado         = false;
    g_fMapaInicio        = GetEngineTime();
    CreateTimer(5.0, Timer_Vigilar, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
    // Los timers con TIMER_FLAG_NO_MAPCHANGE se borran solos: solo limpiar handles
    g_hRotar = null;
    for (int i = 1; i <= MaxClients; i++) g_hHudTimer[i] = null;
}

// ─── SEGUIMIENTO DE LA RONDA ───────────────────────────────────────────────

void TomarScoreInicio()
{
    L4D2_GetVersusCampaignScores(g_iScoreInicio);
    g_bScoreInicioValido = true;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bScoreInicioValido = false;
    CreateTimer(1.0, Timer_ScoreInicio, _, TIMER_FLAG_NO_MAPCHANGE);

    // Secuencia Top 10 -> tu SR al iniciar la ronda (espera a que carguen los jugadores)
    if (g_cvHudRotar.BoolValue && !LibraryExists("readyup"))
        CreateTimer(3.0, Timer_IniciarRotacion, _, TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    PararRotacion();
}

// left4dhooks: el primer survivor salio de la zona segura (respaldo del evento)
public void L4D_OnFirstSurvivorLeftSafeArea_Post(int client)
{
    PararRotacion();
}

bool YaSalieron()
{
    return L4D_HasAnySurvivorLeftSafeArea();
}

public Action Timer_ScoreInicio(Handle timer)
{
    TomarScoreInicio();

    // Campaña nueva: primer mapa, o el marcador volvio a 0-0 (cambiaron de campaña)
    if (g_iMitadesTerminadas == 0)
    {
        if (L4D_IsFirstMapInScenario())
            ReiniciarCampania("primer mapa");
        else if (g_iMitadesTotales > 0 && g_iScoreInicio[0] == 0 && g_iScoreInicio[1] == 0)
            ReiniciarCampania("marcador en 0, campaña nueva");
    }
    return Plugin_Stop;
}

public void Event_SalidaSaferoom(Event event, const char[] name, bool dontBroadcast)
{
    // Al salir del saferoom el marcador ya esta estable: base de esta mitad.
    TomarScoreInicio();
    PararRotacion();
}

// Equipo de campaña (0 o 1) que esta jugando de survivor AHORA, segun el juego.
int IdxSurvivorsSegunJuego()
{
    return (GameRules_GetProp("m_bAreTeamsFlipped") != 0) ? 1 : 0;
}

// Determina que equipo de campaña fue survivor en la mitad que acaba de terminar.
int DeterminarIdxSurvivors(const int[] iScores, char[] sMetodo, int iLen)
{
    // 1) El que sumo puntos en esta mitad es el que estaba de survivor.
    if (g_bScoreInicioValido)
    {
        int d0 = iScores[0] - g_iScoreInicio[0];
        int d1 = iScores[1] - g_iScoreInicio[1];
        if (d0 > d1) { strcopy(sMetodo, iLen, "puntos"); return 0; }
        if (d1 > d0) { strcopy(sMetodo, iLen, "puntos"); return 1; }
    }
    // 2) En la mitad 2 el survivor es el contrario al de la mitad 1.
    if (g_iMitadesTerminadas == 1 && g_iSurvIdxMitad1 != -1)
    {
        strcopy(sMetodo, iLen, "mitad1");
        return 1 - g_iSurvIdxMitad1;
    }
    // 3) Lo que dice el juego.
    strcopy(sMetodo, iLen, "juego");
    return IdxSurvivorsSegunJuego();
}

public void L4D2_OnEndVersusModeRound_Post()
{
    if (!g_cvEnabled.BoolValue) return;

    // Evitar doble disparo del mismo fin de ronda
    float fAhora = GetEngineTime();
    if (fAhora - g_fUltimoFinRonda < 5.0) return;
    g_fUltimoFinRonda = fAhora;

    int iScores[2];
    L4D2_GetVersusCampaignScores(iScores);

    char sMetodo[16];
    int iSurvIdx = DeterminarIdxSurvivors(iScores, sMetodo, sizeof(sMetodo));
    g_bScoreInicioValido = false;

    bool bFinal = L4D_IsMissionFinalMap();

    LogMessage("[SR] Fin de mitad %d | marcador A:%d B:%d | survivors = equipo %s (%s) | mapa final: %s",
        g_iMitadesTerminadas + 1, iScores[0], iScores[1], iSurvIdx == 0 ? "A" : "B", sMetodo,
        bFinal ? "SI" : "NO");

    // Registro: cada uno suma 1 mitad al equipo (A/B) donde jugo esta mitad
    if (!g_bCampaniaCerrada)
    {
        RegistrarPresentes(iSurvIdx, true);
        g_iMitadesTotales++;
    }

    if (g_iMitadesTerminadas == 0)
    {
        g_iSurvIdxMitad1     = iSurvIdx;
        g_iMitadesTerminadas = 1;
        return;
    }

    g_iMitadesTerminadas = 2;

    if (!bFinal)    return;
    if (g_bProcesado) return;
    g_bProcesado = true;

    if (g_bCampaniaCerrada)
    {
        LogMessage("[SR] Fin de campaña: ya se habia cerrado (abandono). No se suma ni resta de nuevo.");
        return;
    }
    ProcesarFinCampania(iScores);
}

// ─── RESULTADO DE LA CAMPAÑA ───────────────────────────────────────────────
//
// REGISTRO DE LA CAMPAÑA (v32)
//   Cada jugador que juega queda anotado por SteamID con:
//     - cuantas MITADES jugo en el equipo A y en el equipo B (se suma al terminar cada mitad,
//       segun el lado en que esta en ese momento)
//     - el ultimo equipo en que se le vio (se actualiza cada 5 s)
//   Al final:
//     - Presente: resultado repartido por partes (mitades en A / total * resultado de A
//       + mitades en B / total * resultado de B).
//     - Se fue y no volvio (jugo al menos sm_mmr_min_mitades): derrota completa
//       + castigo extra (sm_mmr_castigo_salida). Interno, no sale en el panel.
//   Abandono de equipo: si un lado se queda SIN NADIE conectado durante
//   sm_mmr_abandono_espera segundos y el otro lado si tiene gente, la campaña
//   se cierra: los que se quedaron ganan sm_mmr_abandono_pct % de una victoria.
//   Si se van los dos equipos: no pasa nada (anulada, sin castigos).

// Equipo de campaña (0/1) del jugador segun su lado actual. -1 = espectador.
int EquipoCampania(int client, int iSurvIdx)
{
    int t = GetClientTeam(client);
    if (t == TEAM_SURVIVORS) return iSurvIdx;
    if (t == TEAM_INFECTED)  return 1 - iSurvIdx;
    return -1;
}

bool SteamDeCliente(int client, char[] sSteam, int iLen)
{
    if (!GetClientAuthId(client, AuthId_Steam2, sSteam, iLen)) return false;
    if (sSteam[0] == '\0' || StrEqual(sSteam, "STEAM_ID_PENDING") || StrEqual(sSteam, "BOT")) return false;
    return true;
}

int RegBuscar(const char[] sSteam)
{
    for (int r = 0; r < g_iRegCnt; r++)
        if (StrEqual(g_sRegSteam[r], sSteam)) return r;
    return -1;
}

int RegBuscarOCrear(const char[] sSteam)
{
    int r = RegBuscar(sSteam);
    if (r != -1) return r;
    if (g_iRegCnt >= MAX_REG)
    {
        LogError("[SR] Registro de campaña lleno (%d). No se anota %s.", MAX_REG, sSteam);
        return -1;
    }
    r = g_iRegCnt++;
    strcopy(g_sRegSteam[r], sizeof(g_sRegSteam[]), sSteam);
    g_sRegNombre[r][0]    = '\0';
    g_iRegMitades[r][0]   = 0;
    g_iRegMitades[r][1]   = 0;
    g_iRegUltimoEquipo[r] = -1;
    return r;
}

void ReiniciarCampania(const char[] sMotivo)
{
    if (g_iRegCnt > 0 || g_iMitadesTotales > 0)
        LogMessage("[SR] Registro de campaña reiniciado (%s). Mitades previas: %d, jugadores: %d.",
            sMotivo, g_iMitadesTotales, g_iRegCnt);
    g_iRegCnt          = 0;
    g_iMitadesTotales  = 0;
    g_iMaxPorLado      = 0;
    g_bCampaniaCerrada = false;
    g_iSegVacio[0]     = 0;
    g_iSegVacio[1]     = 0;
}

// Anota a los que estan jugando ahora. bFinMitad = suma 1 mitad a su equipo.
void RegistrarPresentes(int iSurvIdx, bool bFinMitad)
{
    int iPorLado[2] = { 0, 0 };
    char sSteam[32];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        int e = EquipoCampania(i, iSurvIdx);
        if (e < 0) continue;
        if (!SteamDeCliente(i, sSteam, sizeof(sSteam))) continue;
        int r = RegBuscarOCrear(sSteam);
        if (r == -1) continue;
        GetClientName(i, g_sRegNombre[r], sizeof(g_sRegNombre[]));
        g_iRegUltimoEquipo[r] = e;
        if (bFinMitad) g_iRegMitades[r][e]++;
        iPorLado[e]++;
    }
    if (bFinMitad)
    {
        if (iPorLado[0] > g_iMaxPorLado) g_iMaxPorLado = iPorLado[0];
        if (iPorLado[1] > g_iMaxPorLado) g_iMaxPorLado = iPorLado[1];
    }
}

// Cliente EN JUEGO con ese SteamID (0 = no esta)
int ClienteEnJuegoDeSteam(const char[] sSteam)
{
    char s[32];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        if (SteamDeCliente(i, s, sizeof(s)) && StrEqual(s, sSteam)) return i;
    }
    return 0;
}

// ¿Hay alguien de ese equipo en el servidor? Cuenta a los que estan jugando en ese lado,
// y a los anotados en ese equipo que siguen conectados (cargando el mapa o de espectador).
bool EquipoConGente(int e, int iSurvIdx)
{
    char sSteam[32];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientConnected(i) || IsFakeClient(i)) continue;
        if (IsClientInGame(i) && EquipoCampania(i, iSurvIdx) == e) return true;
        if (!SteamDeCliente(i, sSteam, sizeof(sSteam))) continue;
        int r = RegBuscar(sSteam);
        if (r != -1 && g_iRegUltimoEquipo[r] == e) return true;
    }
    return false;
}

// ¿Ese equipo tuvo jugadores de verdad en esta campaña? (al menos 1 mitad jugada)
bool EquipoTuvoJugadores(int e)
{
    for (int r = 0; r < g_iRegCnt; r++)
        if (g_iRegUltimoEquipo[r] == e && g_iRegMitades[r][0] + g_iRegMitades[r][1] >= 1) return true;
    return false;
}

// ─── Vigilancia de abandono (cada 5 s) ───

public Action Timer_Vigilar(Handle timer)
{
    if (!g_cvEnabled.BoolValue) return Plugin_Continue;
    if (GetEngineTime() - g_fMapaInicio < 30.0) return Plugin_Continue;   // cargando el mapa

    int iSurvIdx = IdxSurvivorsSegunJuego();
    RegistrarPresentes(iSurvIdx, false);      // solo actualiza "ultimo equipo"

    if (g_bCampaniaCerrada || g_iMitadesTotales < 1)
    {
        g_iSegVacio[0] = 0;
        g_iSegVacio[1] = 0;
        return Plugin_Continue;
    }

    bool bGente[2];
    bGente[0] = EquipoConGente(0, iSurvIdx);
    bGente[1] = EquipoConGente(1, iSurvIdx);

    for (int e = 0; e < 2; e++)
    {
        if (!bGente[e] && bGente[1 - e] && EquipoTuvoJugadores(e))
        {
            if (g_iSegVacio[e] == 0)
                LogMessage("[SR] Equipo %s sin jugadores. Si nadie vuelve en %d s: victoria por abandono del equipo %s.",
                    e == 0 ? "A" : "B", g_cvAbandonoEspera.IntValue, e == 0 ? "B" : "A");
            g_iSegVacio[e] += 5;
        }
        else
        {
            if (g_iSegVacio[e] > 0)
                LogMessage("[SR] Equipo %s volvio a tener jugadores: se cancela el abandono.", e == 0 ? "A" : "B");
            g_iSegVacio[e] = 0;
        }
    }

    for (int e = 0; e < 2; e++)
    {
        if (g_iSegVacio[e] >= g_cvAbandonoEspera.IntValue)
        {
            int iScores[2];
            L4D2_GetVersusCampaignScores(iScores);
            LogMessage("[SR] ABANDONO: el equipo %s se fue. Gana el equipo %s por abandono.",
                e == 0 ? "A" : "B", e == 0 ? "B" : "A");
            ProcesarResultado(1 - e, e, iScores);
            break;
        }
    }
    return Plugin_Continue;
}

// ─── Final normal de la campaña ───

void ProcesarFinCampania(const int[] iScores)
{
    int iGanador = -1;  // 0 = equipo A, 1 = equipo B, -1 = empate
    if      (iScores[0] > iScores[1]) iGanador = 0;
    else if (iScores[1] > iScores[0]) iGanador = 1;

    LogMessage("[SR] FIN DE CAMPAÑA | A:%d - B:%d | ganador: %s | mitades jugadas: %d",
        iScores[0], iScores[1], iGanador == 0 ? "A" : (iGanador == 1 ? "B" : "EMPATE"), g_iMitadesTotales);

    ProcesarResultado(iGanador, -1, iScores);
}

// Cambio Elo (sin redondear) de un resultado contra un rival de promedio fRival
float DeltaElo(int iMio, float fRival, bool bGano, float fK)
{
    float fEsperado = 1.0 / (1.0 + Pow(10.0, (fRival - float(iMio)) / 400.0));
    return fK * ((bGano ? 1.0 : 0.0) - fEsperado);
}

// iGanador: 0/1 (o -1 empate). iAbandono: equipo que abandono (o -1 si es final normal).
void ProcesarResultado(int iGanador, int iAbandono, const int[] iScores)
{
    if (g_bCampaniaCerrada) return;
    g_bCampaniaCerrada = true;      // pase lo que pase, esta campaña ya no se vuelve a procesar
    g_iSegVacio[0] = 0;
    g_iSegVacio[1] = 0;

    if (g_DB == null)
    {
        LogError("[SR] Sin conexion a la DB. SR no actualizado.");
        return;
    }

    int iTot = (g_iMitadesTotales > 0) ? g_iMitadesTotales : 1;
    int iMin = g_cvMinMitades.IntValue;
    if (iMin < 1) iMin = 1;

    // Quien cuenta, su equipo principal y si sigue en el servidor
    bool bCuenta[MAX_REG];
    int  iPrin[MAX_REG], iCli[MAX_REG];
    int  nCont[2] = { 0, 0 };
    for (int r = 0; r < g_iRegCnt; r++)
    {
        int m0 = g_iRegMitades[r][0], m1 = g_iRegMitades[r][1];
        bCuenta[r] = (m0 + m1 >= iMin);
        if      (m0 > m1) iPrin[r] = 0;
        else if (m1 > m0) iPrin[r] = 1;
        else              iPrin[r] = (g_iRegUltimoEquipo[r] == 1) ? 1 : 0;
        iCli[r] = ClienteEnJuegoDeSteam(g_sRegSteam[r]);
        if (bCuenta[r]) nCont[iPrin[r]]++;
    }

    bool bDebug = g_cvDebugMode.BoolValue;
    if ((nCont[0] == 0 || nCont[1] == 0) && !bDebug)
    {
        LogMessage("[SR] Un equipo no tuvo jugadores (A:%d B:%d): no se modifica el SR.", nCont[0], nCont[1]);
        return;
    }

    g_bModoEs1v1 = (g_iMaxPorLado <= 1 && nCont[0] >= 1 && nCont[1] >= 1);

    // SR actual de cada uno (de la tabla del modo) y promedio por equipo
    int   iOld[MAX_REG], iW[MAX_REG], iL[MAX_REG];
    float fSuma[2] = { 0.0, 0.0 };
    for (int r = 0; r < g_iRegCnt; r++)
    {
        if (!bCuenta[r]) continue;
        if (iCli[r] > 0) GetClientName(iCli[r], g_sRegNombre[r], sizeof(g_sRegNombre[]));
        CachearNombreDB(g_sRegSteam[r], g_sRegNombre[r]);
        LeerMMRPorSteamID(g_sRegSteam[r], iOld[r], iW[r], iL[r]);
        fSuma[iPrin[r]] += float(iOld[r]);
    }
    float fProm[2];
    for (int e = 0; e < 2; e++)
        fProm[e] = (nCont[e] > 0) ? fSuma[e] / float(nCont[e]) : float(DEFAULT_MMR);

    float fK       = g_cvKFactor.FloatValue;
    float fPct     = g_cvAbandonoPct.FloatValue / 100.0;
    int   iCastigo = g_cvCastigoSalida.IntValue;
    bool  bEmpate  = (iGanador < 0);

    // Panel de fin
    g_iFinCnt[0]  = 0;
    g_iFinCnt[1]  = 0;
    g_iFinGanador = bEmpate ? -1 : iGanador;
    g_bFin1v1     = g_bModoEs1v1;
    g_bFinAbandono = (iAbandono >= 0);

    int iSurvIdx = IdxSurvivorsSegunJuego();

    for (int r = 0; r < g_iRegCnt; r++)
    {
        if (!bCuenta[r]) continue;

        bool  bPresente = (iCli[r] > 0);
        float fDelta = 0.0;
        int   iRes = 0;          // 1 = suma victoria, -1 = suma derrota, 0 = nada

        if (!bPresente)
        {
            // Se fue y no volvio: derrota completa + castigo (no depende de su equipo)
            fDelta = DeltaElo(iOld[r], fProm[1 - iPrin[r]], false, fK) - float(iCastigo);
            iRes = -1;
        }
        else if (bEmpate)
        {
            fDelta = 0.0;        // empate: los presentes no cambian
            iRes = 0;
        }
        else
        {
            // Por partes: cada equipo en que jugo, segun las mitades jugadas ahi
            for (int e = 0; e < 2; e++)
            {
                int m = g_iRegMitades[r][e];
                if (m <= 0) continue;
                fDelta += (float(m) / float(iTot)) * DeltaElo(iOld[r], fProm[1 - e], e == iGanador, fK);
            }
            if (iAbandono >= 0) fDelta *= fPct;
            iRes = (iPrin[r] == iGanador) ? 1 : -1;
        }

        int iNew = iOld[r] + RoundToNearest(fDelta);
        if (iNew < 0) iNew = 0;
        int w = iW[r] + (iRes == 1 ? 1 : 0);
        int l = iL[r] + (iRes == -1 ? 1 : 0);

        if (iNew != iOld[r] || iRes != 0)
            GuardarMMRPorSteamID(g_sRegSteam[r], iNew, w, l);

        if (bPresente)
        {
            int c = iCli[r];
            if (!g_bModoEs1v1)
            {
                g_iMMR[c] = iNew; g_iWins[c] = w; g_iLosses[c] = l; g_bLoaded[c] = true;
            }
            // En el panel sale en el equipo donde esta ahora (o su equipo principal si es espectador)
            int eP = EquipoCampania(c, iSurvIdx);
            if (eP < 0) eP = iPrin[r];
            int f = g_iFinCnt[eP]++;
            g_iFinCli[eP][f]  = c;
            g_iFinDiff[eP][f] = iNew - iOld[r];
            g_iFinMMR[eP][f]  = iNew;
            strcopy(g_sFinNom[eP][f], MAX_NAME_LENGTH, g_sRegNombre[r]);
        }

        LogMessage("[SR]   %s %s (%s) A:%d B:%d mitades: %d -> %d (%s%d)",
            !bPresente ? "SE FUE" : (iRes == 1 ? "GANO  " : (iRes == -1 ? "PERDIO" : "EMPATE")),
            g_sRegNombre[r], g_sRegSteam[r], g_iRegMitades[r][0], g_iRegMitades[r][1],
            iOld[r], iNew, iNew >= iOld[r] ? "+" : "", iNew - iOld[r]);
    }

    // Historial
    char sModo[8];
    if (nCont[0] == 0 || nCont[1] == 0) strcopy(sModo, sizeof(sModo), "debug");
    else if (iAbandono >= 0)            strcopy(sModo, sizeof(sModo), g_bModoEs1v1 ? "ab1v1" : "ab4v4");
    else                                strcopy(sModo, sizeof(sModo), g_bModoEs1v1 ? "1v1" : "4v4");
    GuardarPartida(iScores, bEmpate ? 0 : iGanador + 1, sModo, bCuenta, iPrin, iCli);

    g_bModoEs1v1 = false;

    if (bEmpate) MostrarEmpateATodos();
    else         MostrarFinATodos();

    if (g_cvWebScript.BoolValue)
        CreateTimer(5.0, Timer_GenerarIndexHTML);
}

// Historial: grupo 1 = equipo A, grupo 2 = equipo B (segun su equipo principal).
// Los que se fueron salen con "(se fue)" en el historial.
void GuardarPartida(const int[] iScores, int iGanadorGrupo, const char[] sModo,
                    const bool[] bCuenta, const int[] iPrin, const int[] iCli)
{
    if (g_DB == null) return;

    SQL_FastQuery(g_DB,
        "CREATE TABLE IF NOT EXISTS mmr_partidas ( \
            id INTEGER PRIMARY KEY AUTOINCREMENT, fecha INTEGER NOT NULL, mapa TEXT NOT NULL, \
            puntos_grupo1 INTEGER DEFAULT 0, puntos_grupo2 INTEGER DEFAULT 0, \
            duracion_seg INTEGER DEFAULT 0, ganador_grupo INTEGER DEFAULT 0, modo TEXT DEFAULT '4v4' );");
    SQL_FastQuery(g_DB,
        "CREATE TABLE IF NOT EXISTS mmr_partida_jugadores ( \
            partida_id INTEGER NOT NULL, steamid TEXT NOT NULL, nombre TEXT NOT NULL, grupo INTEGER NOT NULL );");

    char sMapa[64], sMapaSafe[128];
    GetCurrentMap(sMapa, sizeof(sMapa));
    SQL_EscapeString(g_DB, sMapa, sMapaSafe, sizeof(sMapaSafe));

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "INSERT INTO mmr_partidas (fecha, mapa, puntos_grupo1, puntos_grupo2, duracion_seg, ganador_grupo, modo) \
         VALUES (%d, '%s', %d, %d, 0, %d, '%s');",
        GetTime(), sMapaSafe, iScores[0], iScores[1], iGanadorGrupo, sModo);

    DBResultSet rs = SQL_Query(g_DB, sQuery);
    if (rs == null)
    {
        LogError("[SR] No se pudo guardar la partida en el historial.");
        return;
    }
    int iPartidaId = SQL_GetInsertId(g_DB);
    delete rs;

    char sNombre[MAX_NAME_LENGTH + 16], sEscSteam[128], sEscNom[(MAX_NAME_LENGTH + 16) * 2];
    for (int r = 0; r < g_iRegCnt; r++)
    {
        if (!bCuenta[r]) continue;
        if (iCli[r] > 0) strcopy(sNombre, sizeof(sNombre), g_sRegNombre[r]);
        else             Format(sNombre, sizeof(sNombre), "%s (se fue)", g_sRegNombre[r]);
        SQL_EscapeString(g_DB, g_sRegSteam[r], sEscSteam, sizeof(sEscSteam));
        SQL_EscapeString(g_DB, sNombre,        sEscNom,   sizeof(sEscNom));
        Format(sQuery, sizeof(sQuery),
            "INSERT INTO mmr_partida_jugadores (partida_id, steamid, nombre, grupo) VALUES (%d, '%s', '%s', %d);",
            iPartidaId, sEscSteam, sEscNom, iPrin[r] + 1);
        SQL_FastQuery(g_DB, sQuery);
    }

    LogMessage("[SR] Partida #%d guardada (%s, %s, A:%d B:%d, ganador grupo %d).",
        iPartidaId, sModo, sMapa, iScores[0], iScores[1], iGanadorGrupo);
}

// ─── COMANDOS NUEVOS ──────────────────────────────────────────────────────

public Action Cmd_StatusMMR(int client, int args)
{
    int iScores[2];
    L4D2_GetVersusCampaignScores(iScores);
    int iSurvIdx = IdxSurvivorsSegunJuego();

    char sMapa[64];
    GetCurrentMap(sMapa, sizeof(sMapa));

    ReplyToCommand(client, "[SR] ——— Estado v%s ———", PLUGIN_VERSION);
    ReplyToCommand(client, "[SR] Activo: %s | K: %.0f | Debug: %s | DB: %s",
        g_cvEnabled.BoolValue ? "SI" : "NO", g_cvKFactor.FloatValue,
        g_cvDebugMode.BoolValue ? "SI" : "NO", g_DB != null ? "OK" : "ERROR");
    ReplyToCommand(client, "[SR] Mapa: %s | Final: %s | Mitad actual: %d",
        sMapa, L4D_IsMissionFinalMap() ? "SI" : "NO", g_iMitadesTerminadas + 1);

    for (int e = 0; e < 2; e++)
    {
        char sLista[512] = "";
        int n = 0;
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsValidHuman(i)) continue;
            if (EquipoCampania(i, iSurvIdx) != e) continue;
            char sNom[MAX_NAME_LENGTH];
            GetClientName(i, sNom, sizeof(sNom));
            if (n > 0) StrCat(sLista, sizeof(sLista), ", ");
            StrCat(sLista, sizeof(sLista), sNom);
            n++;
        }
        ReplyToCommand(client, "[SR] Equipo %s (%s ahora, %d jug): %d pts | %s",
            e == 0 ? "A" : "B", (e == iSurvIdx) ? "survivor" : "infected", n, iScores[e],
            n > 0 ? sLista : "(vacio)");
    }

    if      (iScores[0] > iScores[1]) ReplyToCommand(client, "[SR] Va ganando: Equipo A (+%d)", iScores[0] - iScores[1]);
    else if (iScores[1] > iScores[0]) ReplyToCommand(client, "[SR] Va ganando: Equipo B (+%d)", iScores[1] - iScores[0]);
    else                              ReplyToCommand(client, "[SR] Va: EMPATE");

    ReplyToCommand(client, "[SR] Registro de la campaña: %d mitades | %s | abandono A:%ds B:%ds",
        g_iMitadesTotales, g_bCampaniaCerrada ? "CERRADA" : "abierta", g_iSegVacio[0], g_iSegVacio[1]);
    for (int r = 0; r < g_iRegCnt; r++)
    {
        ReplyToCommand(client, "[SR]   %s | mitades A:%d B:%d | ultimo: %s | %s",
            g_sRegNombre[r], g_iRegMitades[r][0], g_iRegMitades[r][1],
            g_iRegUltimoEquipo[r] == 0 ? "A" : (g_iRegUltimoEquipo[r] == 1 ? "B" : "-"),
            ClienteEnJuegoDeSteam(g_sRegSteam[r]) > 0 ? "en el server" : "FUERA");
    }

    return Plugin_Handled;
}

public Action Cmd_ReloadMMR(int client, int args)
{
    if (g_DB == null) InitDatabase();
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        g_bLoaded[i] = false;
        LoadPlayerMMR(i);
        n++;
    }
    ReplyToCommand(client, "[SR] DB %s. Jugadores recargados: %d", g_DB != null ? "OK" : "ERROR", n);
    return Plugin_Handled;
}

// ─── CONEXIONES ───────────────────────────────────────────────────────────

public void OnClientPostAdminCheck(int client)
{
    if (!IsValidHuman(client)) return;
    g_bLoaded[client] = false;
    g_iMMR[client]    = DEFAULT_MMR;
    g_iWins[client]   = 0;
    g_iLosses[client] = 0;
    LoadPlayerMMR(client);
}

public void OnClientDisconnect(int client)
{
    // Todo se guarda en la DB en el momento: aca solo se limpia el slot.
    g_hHudTimer[client]  = null;   // el timer se corta solo (userid invalido)
    g_iHudLineas[client] = 0;
    g_iRank[client]      = 0;
    g_bLoaded[client] = false;
    g_iMMR[client]    = DEFAULT_MMR;
    g_iWins[client]   = 0;
    g_iLosses[client] = 0;
}

// =========================================================================
// Funciones reutilizadas de la version anterior (DB, comandos, HUD, web)
// =========================================================================

// Buffers grandes de la web (globales para no desbordar el stack)
static char g_sWebHtml[65535];
static char g_sWebRanking[32768];
static char g_sWebPartidas[16384];

void InitDatabase()
{
    // Abrir nuestra PROPIA conexion a la DB (ya no dependemos del core).
    // Esto evita que el core (cl4d2_mmr_core) interfiera escribiendo en
    // las mismas tablas y corrompiendo los datos del 1v1.
    char sError[256];
    g_DB = SQLite_UseDatabase("l4d2_mmr", sError, sizeof(sError));

    if (g_DB == null)
    {
        LogError("[SR] No se pudo abrir la DB l4d2_mmr.sq3: %s", sError);
        return;
    }

    // Crear las tablas si no existen (ya no dependemos de que el core las cree)
    SQL_FastQuery(g_DB,
        "CREATE TABLE IF NOT EXISTS mmr_players (steamid TEXT NOT NULL PRIMARY KEY, \
         nombre TEXT DEFAULT '', mmr INTEGER NOT NULL DEFAULT 500, \
         wins INTEGER NOT NULL DEFAULT 0, losses INTEGER NOT NULL DEFAULT 0, \
         last_update INTEGER NOT NULL DEFAULT 0);");
    SQL_FastQuery(g_DB,
        "CREATE TABLE IF NOT EXISTS mmr_players_1v1 (steamid TEXT NOT NULL PRIMARY KEY, \
         nombre TEXT DEFAULT '', mmr INTEGER NOT NULL DEFAULT 500, \
         wins INTEGER NOT NULL DEFAULT 0, losses INTEGER NOT NULL DEFAULT 0, \
         last_update INTEGER NOT NULL DEFAULT 0);");

    LogMessage("[SR] Conectado a la DB (conexion propia). Tablas listas.");
}

void LoadPlayerMMR(int client)
{
    if (g_DB == null) return;

    char sSteamID[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID))
     || sSteamID[0] == '\0'
     || strcmp(sSteamID, "STEAM_ID_PENDING") == 0)
    {
        DataPack dp;
        CreateDataTimer(2.0, Timer_RetryLoad, dp);   // dp es de SALIDA
        dp.WriteCell(GetClientUserId(client));
        return;
    }

    char sEscaped[128];
    SQL_EscapeString(g_DB, sSteamID, sEscaped, sizeof(sEscaped));
    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "SELECT mmr, wins, losses FROM mmr_players WHERE steamid = '%s';", sEscaped);

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    dp.WriteString(sSteamID);
    SQL_TQuery(g_DB, Callback_LoadMMR, sQuery, dp);
}

public Action Timer_RetryLoad(Handle timer, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientConnected(client) || !IsValidHuman(client)) return Plugin_Stop;
    if (g_bLoaded[client]) return Plugin_Stop;
    LoadPlayerMMR(client);
    return Plugin_Stop;
}

public void Callback_LoadMMR(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    char sSteamID[64];
    dp.ReadString(sSteamID, sizeof(sSteamID));
    delete dp;

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientConnected(client)) return;
    if (results == null || sError[0] != '\0') { LogError("[SR] Callback_LoadSR error: %s", sError); return; }


    if (results.FetchRow())
    {
        g_iMMR[client]    = results.FetchInt(0);
        g_iWins[client]   = results.FetchInt(1);
        g_iLosses[client] = results.FetchInt(2);
    }
    else
    {
        InsertNewPlayer(client, sSteamID);
        g_iMMR[client]    = DEFAULT_MMR;
        g_iWins[client]   = 0;
        g_iLosses[client] = 0;
    }

    g_bLoaded[client] = true;
}

void InsertNewPlayer(int client, const char[] sSteamID)
{
    if (g_DB == null) return;
    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));
    char sEscapedID[128], sEscapedName[MAX_NAME_LENGTH * 2];
    SQL_EscapeString(g_DB, sSteamID, sEscapedID,  sizeof(sEscapedID));
    SQL_EscapeString(g_DB, sName,    sEscapedName, sizeof(sEscapedName));
    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "INSERT OR IGNORE INTO mmr_players (steamid, nombre, mmr, wins, losses, last_update) \
         VALUES ('%s', '%s', %d, 0, 0, %d);",
        sEscapedID, sEscapedName, DEFAULT_MMR, GetTime());
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);
}

void SavePlayerMMR(int client)
{
    if (g_DB == null || !g_bLoaded[client]) return;
    char sSteamID[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID))) return;
    char sName[MAX_NAME_LENGTH];
    GetClientName(client, sName, sizeof(sName));
    char sEscapedID[128], sEscapedName[MAX_NAME_LENGTH * 2];
    SQL_EscapeString(g_DB, sSteamID, sEscapedID,  sizeof(sEscapedID));
    SQL_EscapeString(g_DB, sName,    sEscapedName, sizeof(sEscapedName));

    // Decidir tabla segun el modo: mmr_players (4v4) o mmr_players_1v1
    char sTable[32];
    strcopy(sTable, sizeof(sTable), g_bModoEs1v1 ? "mmr_players_1v1" : "mmr_players");

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "INSERT INTO %s (steamid, nombre, mmr, wins, losses, last_update) \
         VALUES ('%s', '%s', %d, %d, %d, %d) \
         ON CONFLICT(steamid) DO UPDATE SET \
             nombre=excluded.nombre, mmr=excluded.mmr, \
             wins=excluded.wins, losses=excluded.losses, \
             last_update=excluded.last_update;",
        sTable, sEscapedID, sEscapedName,
        g_iMMR[client], g_iWins[client], g_iLosses[client], GetTime());
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);
}

public void Callback_GenericSQL(Database db, DBResultSet results, const char[] sError, any data)
{
    if (sError[0] != '\0') LogError("[SR] SQL Error: %s", sError);
}

// Lee MMR/wins/losses de un SteamID directo de la DB (tabla del modo
// actual). Si el jugador no existe en la tabla, lo crea con DEFAULT_MMR.
// Funciona este el jugador conectado o no.
void LeerMMRPorSteamID(const char[] sSteamID, int &iMMR, int &iWins, int &iLosses)
{
    iMMR = DEFAULT_MMR; iWins = 0; iLosses = 0;
    if (g_DB == null || sSteamID[0] == '\0') return;

    char sEsc[128];
    SQL_EscapeString(g_DB, sSteamID, sEsc, sizeof(sEsc));

    char sTable[32];
    strcopy(sTable, sizeof(sTable), g_bModoEs1v1 ? "mmr_players_1v1" : "mmr_players");

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "SELECT mmr, wins, losses FROM %s WHERE steamid = '%s';", sTable, sEsc);

    DBResultSet rs = SQL_Query(g_DB, sQuery);
    if (rs != null && rs.FetchRow())
    {
        iMMR    = rs.FetchInt(0);
        iWins   = rs.FetchInt(1);
        iLosses = rs.FetchInt(2);
        delete rs;
        return;
    }
    if (rs != null) delete rs;

    // No existe: crearlo. El nombre se pone como "Desconocido" aqui,
    // pero CachearNombreDB lo actualiza al nombre real cuando el jugador
    // entra al roster (mientras sigue conectado).
    Format(sQuery, sizeof(sQuery),
        "INSERT OR IGNORE INTO %s (steamid, nombre, mmr, wins, losses, last_update) VALUES ('%s', 'Desconocido', %d, 0, 0, %d);",
        sTable, sEsc, DEFAULT_MMR, GetTime());
    SQL_FastQuery(g_DB, sQuery);
}

// Guarda el nombre real del jugador en la DB en cuanto entra al roster.
// Asi, aunque se desconecte antes de terminar la campaña, su nombre
// ya queda guardado y no sale "Desconocido" al actualizar el MMR.
void CachearNombreDB(const char[] sSteamID, const char[] sNombre)
{
    if (g_DB == null || sSteamID[0] == '\0' || sNombre[0] == '\0') return;

    char sEscID[128], sEscNom[256];
    SQL_EscapeString(g_DB, sSteamID, sEscID, sizeof(sEscID));
    SQL_EscapeString(g_DB, sNombre,  sEscNom, sizeof(sEscNom));

    char sTable[32];
    strcopy(sTable, sizeof(sTable), g_bModoEs1v1 ? "mmr_players_1v1" : "mmr_players");

    // INSERT OR IGNORE crea el jugador si no existe (con nombre correcto),
    // y el UPDATE lo actualiza si ya existia con nombre viejo o "Desconocido".
    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "INSERT OR IGNORE INTO %s (steamid, nombre, mmr, wins, losses, last_update) VALUES ('%s', '%s', %d, 0, 0, %d);",
        sTable, sEscID, sEscNom, DEFAULT_MMR, GetTime());
    SQL_FastQuery(g_DB, sQuery);

    Format(sQuery, sizeof(sQuery),
        "UPDATE %s SET nombre = '%s', last_update = %d WHERE steamid = '%s';",
        sTable, sEscNom, GetTime(), sEscID);
    SQL_FastQuery(g_DB, sQuery);
}

// Guarda MMR/wins/losses de un SteamID en la DB (tabla del modo actual).
void GuardarMMRPorSteamID(const char[] sSteamID, int iMMR, int iWins, int iLosses)
{
    if (g_DB == null || sSteamID[0] == '\0') return;

    char sEsc[128];
    SQL_EscapeString(g_DB, sSteamID, sEsc, sizeof(sEsc));

    char sTable[32];
    strcopy(sTable, sizeof(sTable), g_bModoEs1v1 ? "mmr_players_1v1" : "mmr_players");

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "UPDATE %s SET mmr = %d, wins = %d, losses = %d, last_update = %d WHERE steamid = '%s';",
        sTable, iMMR, iWins, iLosses, GetTime(), sEsc);
    SQL_FastQuery(g_DB, sQuery);
}

int CalculateNewMMR(int iMyMMR, float fOpponentAvg, bool bWon, float fK)
{
    float fExpected = 1.0 / (1.0 + Pow(10.0, (fOpponentAvg - float(iMyMMR)) / 400.0));
    float fActual   = bWon ? 1.0 : 0.0;
    int   iNew      = iMyMMR + RoundToNearest(fK * (fActual - fExpected));
    if (iNew < 0) iNew = 0;
    return iNew;
}

void ObtenerRango(int iMMR, char[] sRango, int iMaxRango, char[] sColor, int iMaxColor)
{
    if (iMMR >= RANGO_LEYENDA)       { strcopy(sRango, iMaxRango, "Leyenda");   strcopy(sColor, iMaxColor, "\x04"); }
    else if (iMMR >= RANGO_MAESTRO)  { strcopy(sRango, iMaxRango, "Maestro");   strcopy(sColor, iMaxColor, "\x04"); }
    else if (iMMR >= RANGO_DIAMANTE) { strcopy(sRango, iMaxRango, "Diamante");  strcopy(sColor, iMaxColor, "\x05"); }
    else if (iMMR >= RANGO_PLATINO)  { strcopy(sRango, iMaxRango, "Platino");   strcopy(sColor, iMaxColor, "\x05"); }
    else if (iMMR >= RANGO_ORO)      { strcopy(sRango, iMaxRango, "Oro");       strcopy(sColor, iMaxColor, "\x04"); }
    else if (iMMR >= RANGO_PLATA)    { strcopy(sRango, iMaxRango, "Plata");     strcopy(sColor, iMaxColor, "\x01"); }
    else if (iMMR >= RANGO_BRONCE)   { strcopy(sRango, iMaxRango, "Bronce");    strcopy(sColor, iMaxColor, "\x07"); }
    else                              { strcopy(sRango, iMaxRango, "Hierro");    strcopy(sColor, iMaxColor, "\x07"); }
}





// =============================================
// sm_mmr_testhud: panel de fin de campaña con los jugadores que estan ahora,
// con cambios de MMR inventados. NO guarda nada en la DB.
// =============================================
public Action Cmd_TestHud(int client, int args)
{
    int iSurvIdx = IdxSurvivorsSegunJuego();
    g_iFinCnt[0] = 0;
    g_iFinCnt[1] = 0;
    g_iFinGanador = iSurvIdx;     // en la prueba "ganan" los survivors actuales
    g_bFin1v1 = false;
    g_bFinAbandono = false;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        int e = EquipoCampania(i, iSurvIdx);
        if (e < 0) continue;
        int f = g_iFinCnt[e]++;
        int iDiff = (e == g_iFinGanador) ? GetRandomInt(20, 45) : -GetRandomInt(20, 45);
        g_iFinCli[e][f]  = i;
        g_iFinDiff[e][f] = iDiff;
        g_iFinMMR[e][f]  = g_iMMR[i] + iDiff;
        GetClientName(i, g_sFinNom[e][f], MAX_NAME_LENGTH);
    }

    MostrarFinATodos();
    ReplyToCommand(client, "[SR] Panel de prueba mostrado (no se guardo nada).");
    return Plugin_Handled;
}

bool IsValidHuman(int client)
{
    return (client >= 1 && client <= MaxClients
         && IsClientConnected(client)
         && IsClientInGame(client)
         && !IsFakeClient(client));
}

public Action Cmd_MMR(int client, int args)
{
    if (client == 0) { PrintToServer("[SR] Solo para jugadores."); return Plugin_Handled; }
    if (!g_bLoaded[client])
    {
        PanelAviso(client, "ClubCampestre :: Mi SR", "Cargando datos, espera un momento...");
        LoadPlayerMMR(client);
        return Plugin_Handled;
    }
    char sSteamID[64];
    GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID));
    char sEscaped[128];
    SQL_EscapeString(g_DB, sSteamID, sEscaped, sizeof(sEscaped));
    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "SELECT COUNT(*)+1 FROM mmr_players WHERE mmr > \
        (SELECT mmr FROM mmr_players WHERE steamid='%s');", sEscaped);
    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    SQL_TQuery(g_DB, Callback_ShowMMR, sQuery, dp);
    return Plugin_Handled;
}

public void Callback_ShowMMR(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int client = GetClientOfUserId(dp.ReadCell());
    delete dp;
    if (client == 0 || !IsClientInGame(client)) return;

    if (results != null && sError[0] == '\0' && results.FetchRow())
        g_iRank[client] = results.FetchInt(0);

    ArmarPanelMMR(client);
    HudMostrar(client, g_cvHudSegCmd.IntValue);
}

public Action Cmd_Top(int client, int args)
{
    if (g_DB == null) return Plugin_Handled;
    DataPack dp = new DataPack();
    dp.WriteCell((client == 0) ? 0 : GetClientUserId(client));
    SQL_TQuery(g_DB, Callback_Top,
        "SELECT nombre, mmr, wins, losses, steamid FROM mmr_players \
         WHERE (wins + losses) >= 1 \
         ORDER BY mmr DESC LIMIT 10;", dp);
    return Plugin_Handled;
}

public void Callback_Top(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    delete dp;
    if (results == null || sError[0] != '\0') return;

    GuardarTopCache(results);

    if (userid == 0)
    {
        PrintToServer("[SR] ——— Top 10 SR ———");
        for (int i = 0; i < g_iTopCnt; i++)
            PrintToServer("[SR] #%d %s — %d SR (W:%d/L:%d)", i + 1, g_sTopNom[i], g_iTopMMR[i], g_iTopW[i], g_iTopL[i]);
        return;
    }

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client)) return;
    ArmarPanelTop(client);
    HudMostrar(client, g_cvHudSegCmd.IntValue);
}

public Action Cmd_MMRJugador(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "[SR] Uso: sm_mmr_jugador <nombre>"); return Plugin_Handled; }
    char sArg[64];
    GetCmdArg(1, sArg, sizeof(sArg));

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));
        if (StrContains(sName, sArg, false) != -1)
        {
            if (client == 0)
                PrintToServer("[SR] %s -> SR: %d (W:%d/L:%d)", sName, g_iMMR[i], g_iWins[i], g_iLosses[i]);
            else
                PanelJugador(client, "ClubCampestre :: Jugador", sName, g_iMMR[i], g_iWins[i], g_iLosses[i]);
            return Plugin_Handled;
        }
    }

    char sEscaped[128];
    SQL_EscapeString(g_DB, sArg, sEscaped, sizeof(sEscaped));
    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "SELECT nombre, mmr, wins, losses FROM mmr_players \
         WHERE nombre LIKE '%%%s%%' ORDER BY mmr DESC LIMIT 1;", sEscaped);
    DataPack dp = new DataPack();
    dp.WriteCell((client == 0) ? 0 : GetClientUserId(client));
    SQL_TQuery(g_DB, Callback_MMRJugador, sQuery, dp);
    return Plugin_Handled;
}

public void Callback_MMRJugador(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    delete dp;
    int client = (userid == 0) ? 0 : GetClientOfUserId(userid);
    if (userid != 0 && (client == 0 || !IsClientInGame(client))) return;

    if (results == null || sError[0] != '\0')
    {
        if (client == 0) PrintToServer("[SR] Error en DB.");
        else PanelAviso(client, "ClubCampestre :: Jugador", "Error consultando la base de datos.");
        return;
    }
    if (results.FetchRow())
    {
        char sName[MAX_NAME_LENGTH];
        results.FetchString(0, sName, sizeof(sName));
        if (sName[0] == '\0') strcopy(sName, sizeof(sName), "Desconocido");
        int iMMR = results.FetchInt(1), iW = results.FetchInt(2), iL = results.FetchInt(3);
        if (client == 0) PrintToServer("[SR] %s -> SR: %d (W:%d/L:%d)", sName, iMMR, iW, iL);
        else PanelJugador(client, "ClubCampestre :: Jugador", sName, iMMR, iW, iL);
    }
    else
    {
        if (client == 0) PrintToServer("[SR] Jugador no encontrado.");
        else PanelAviso(client, "ClubCampestre :: Jugador", "Jugador no encontrado.");
    }
}

public Action Cmd_SetMMR(int client, int args)
{
    if (args < 2) { ReplyToCommand(client, "[SR] Uso: sm_setmmr <target> <cantidad>"); return Plugin_Handled; }
    char sTarget[64], sAmount[16];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    GetCmdArg(2, sAmount, sizeof(sAmount));
    int target = FindClientByName(sTarget);
    if (target == -1) { ReplyToCommand(client, "[SR] Jugador '%s' no encontrado.", sTarget); return Plugin_Handled; }
    int iOld = g_iMMR[target];
    g_iMMR[target] = StringToInt(sAmount);
    SavePlayerMMR(target);
    char sName[MAX_NAME_LENGTH];
    GetClientName(target, sName, sizeof(sName));
    ReplyToCommand(client, "[SR] SR de %s: %d → %d", sName, iOld, g_iMMR[target]);
    char sAviso[96];
    Format(sAviso, sizeof(sAviso), "Un admin ajusto tu SR: %d -> %d", iOld, g_iMMR[target]);
    PanelAviso(target, "ClubCampestre :: SR", sAviso);
    return Plugin_Handled;
}

public Action Cmd_ResetMMR(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "[SR] Uso: sm_resetmmr <target>"); return Plugin_Handled; }
    char sTarget[64];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    int target = FindClientByName(sTarget);
    if (target == -1) { ReplyToCommand(client, "[SR] Jugador '%s' no encontrado.", sTarget); return Plugin_Handled; }
    g_iMMR[target]    = DEFAULT_MMR;
    g_iWins[target]   = 0;
    g_iLosses[target] = 0;
    SavePlayerMMR(target);
    char sName[MAX_NAME_LENGTH];
    GetClientName(target, sName, sizeof(sName));
    ReplyToCommand(client, "[SR] SR de %s reseteado a %d.", sName, DEFAULT_MMR);
    char sAviso[96];
    Format(sAviso, sizeof(sAviso), "Un admin reseteo tu SR a %d", DEFAULT_MMR);
    PanelAviso(target, "ClubCampestre :: SR", sAviso);
    return Plugin_Handled;
}

int FindClientByName(const char[] sPartial)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        char sName[MAX_NAME_LENGTH];
        GetClientName(i, sName, sizeof(sName));
        if (StrContains(sName, sPartial, false) != -1) return i;
    }
    return -1;
}

// ============================================================
// COMANDOS DEL MODO 1v1
// Leen directamente de la tabla mmr_players_1v1
// ============================================================
public Action Cmd_MMR1v1(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[SR 1v1] Comando solo para jugadores.");
        return Plugin_Handled;
    }

    char sSteamID[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID)))
    {
        PanelAviso(client, "ClubCampestre :: Mi SR 1v1", "No se pudo obtener tu SteamID.");
        return Plugin_Handled;
    }

    char sEscaped[128];
    SQL_EscapeString(g_DB, sSteamID, sEscaped, sizeof(sEscaped));
    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "SELECT mmr, wins, losses FROM mmr_players_1v1 WHERE steamid = '%s';", sEscaped);

    DataPack dp = new DataPack();
    dp.WriteCell(GetClientUserId(client));
    SQL_TQuery(g_DB, Callback_ShowMMR1v1, sQuery, dp);

    return Plugin_Handled;
}

public void Callback_ShowMMR1v1(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    delete dp;

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client)) return;
    if (results == null || sError[0] != '\0') return;

    int iMMR = DEFAULT_MMR, iW = 0, iL = 0;
    if (results.FetchRow())
    {
        iMMR = results.FetchInt(0);
        iW   = results.FetchInt(1);
        iL   = results.FetchInt(2);
    }

    char sNombre[MAX_NAME_LENGTH];
    GetClientName(client, sNombre, sizeof(sNombre));
    PanelJugador(client, "ClubCampestre :: Mi SR 1v1", sNombre, iMMR, iW, iL);
}

public Action Cmd_Top1v1(int client, int args)
{
    if (g_DB == null)
    {
        ReplyToCommand(client, "[SR 1v1] DB no disponible.");
        return Plugin_Handled;
    }

    DataPack dp = new DataPack();
    dp.WriteCell((client == 0) ? 0 : GetClientUserId(client));

    SQL_TQuery(g_DB, Callback_Top1v1,
        "SELECT nombre, mmr, wins, losses, steamid FROM mmr_players_1v1 WHERE (wins + losses) >= 1 ORDER BY mmr DESC LIMIT 10;",
        dp);

    return Plugin_Handled;
}

public void Callback_Top1v1(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    delete dp;

    int client = (userid == 0) ? 0 : GetClientOfUserId(userid);
    if (userid != 0 && (client == 0 || !IsClientInGame(client))) return;

    if (results == null || sError[0] != '\0')
    {
        if (client == 0) PrintToServer("[SR 1v1] Error consultando el top.");
        else PanelAviso(client, "ClubCampestre :: Top 10 SR 1v1", "Error consultando el top.");
        return;
    }

    char sMiSteam[32] = "";
    if (client != 0) GetClientAuthId(client, AuthId_Steam2, sMiSteam, sizeof(sMiSteam));

    char sLinea[HUD_LARGO_LINEA], sName[MAX_NAME_LENGTH], sSteam[32];
    if (client != 0) HudCabecera(client, "ClubCampestre :: Top 10 SR 1v1");
    else PrintToServer("===== TOP 10 - MODO 1v1 =====");

    int rank = 1;
    while (results.FetchRow())
    {
        results.FetchString(0, sName, sizeof(sName));
        if (sName[0] == '\0') strcopy(sName, sizeof(sName), "Desconocido");
        int iMMR = results.FetchInt(1);
        int iW   = results.FetchInt(2);
        int iL   = results.FetchInt(3);
        results.FetchString(4, sSteam, sizeof(sSteam));

        if (client == 0)
        {
            PrintToServer("%d. %s - %d SR (%dW/%dL)", rank, sName, iMMR, iW, iL);
        }
        else
        {
            LineaTop(sLinea, sizeof(sLinea), rank, iMMR, iW, iL, sName);
            if (sMiSteam[0] != '\0' && StrEqual(sSteam, sMiSteam)) HudNaranja(client, sLinea);
            else                                                   HudTexto(client, sLinea);
        }
        rank++;
    }

    if (client == 0)
    {
        if (rank == 1) PrintToServer("(Sin datos todavia - juega una partida 1v1)");
        return;
    }
    if (rank == 1) HudTexto(client, "Sin datos todavia - juega una partida 1v1");
    HudMostrar(client, g_cvHudSegCmd.IntValue);
}

public Action Cmd_SetMMR1v1(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[SR 1v1] Uso: sm_setmmr1v1 <target> <cantidad>");
        return Plugin_Handled;
    }

    char sTarget[64], sAmount[16];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    GetCmdArg(2, sAmount, sizeof(sAmount));

    int iTarget = FindTarget(client, sTarget, true, false);
    if (iTarget == -1) return Plugin_Handled;

    int iNewMMR = StringToInt(sAmount);
    if (iNewMMR < 0) iNewMMR = 0;

    char sSteamID[64];
    if (!GetClientAuthId(iTarget, AuthId_Steam2, sSteamID, sizeof(sSteamID))) return Plugin_Handled;

    char sName[MAX_NAME_LENGTH];
    GetClientName(iTarget, sName, sizeof(sName));

    char sEscID[128], sEscName[MAX_NAME_LENGTH * 2];
    SQL_EscapeString(g_DB, sSteamID, sEscID, sizeof(sEscID));
    SQL_EscapeString(g_DB, sName, sEscName, sizeof(sEscName));

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "INSERT INTO mmr_players_1v1 (steamid, nombre, mmr, wins, losses, last_update) \
         VALUES ('%s', '%s', %d, 0, 0, %d) \
         ON CONFLICT(steamid) DO UPDATE SET mmr=%d, last_update=%d;",
        sEscID, sEscName, iNewMMR, GetTime(), iNewMMR, GetTime());
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);

    ReplyToCommand(client, "[SR 1v1] SR 1v1 de %N ajustado a %d.", iTarget, iNewMMR);
    return Plugin_Handled;
}

public Action Cmd_ResetMMR1v1(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SR 1v1] Uso: sm_resetmmr1v1 <target>");
        return Plugin_Handled;
    }

    char sTarget[64];
    GetCmdArg(1, sTarget, sizeof(sTarget));

    int iTarget = FindTarget(client, sTarget, true, false);
    if (iTarget == -1) return Plugin_Handled;

    char sSteamID[64];
    if (!GetClientAuthId(iTarget, AuthId_Steam2, sSteamID, sizeof(sSteamID))) return Plugin_Handled;

    char sEscID[128];
    SQL_EscapeString(g_DB, sSteamID, sEscID, sizeof(sEscID));

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "UPDATE mmr_players_1v1 SET mmr=%d, wins=0, losses=0, last_update=%d WHERE steamid='%s';",
        DEFAULT_MMR, GetTime(), sEscID);
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);

    ReplyToCommand(client, "[SR 1v1] SR 1v1 de %N reseteado a %d.", iTarget, DEFAULT_MMR);
    return Plugin_Handled;
}

void ObtenerRangoWebColors(int iMMR, char[] sRango, int rLen,
                           char[] sC1, int c1Len, char[] sC2, int c2Len)
{
    if      (iMMR >= 2000) { strcopy(sRango,rLen,"leyenda");  strcopy(sC1,c1Len,"#ff7038"); strcopy(sC2,c2Len,"#cf4010"); }
    else if (iMMR >= 1500) { strcopy(sRango,rLen,"maestro");  strcopy(sC1,c1Len,"#a45dff"); strcopy(sC2,c2Len,"#742dcc"); }
    else if (iMMR >= 1200) { strcopy(sRango,rLen,"diamante"); strcopy(sC1,c1Len,"#3fb0ff"); strcopy(sC2,c2Len,"#1f80cf"); }
    else if (iMMR >= 1000) { strcopy(sRango,rLen,"platino");  strcopy(sC1,c1Len,"#2ee0cc"); strcopy(sC2,c2Len,"#1eb0a0"); }
    else if (iMMR >=  800) { strcopy(sRango,rLen,"oro");      strcopy(sC1,c1Len,"#ffcf40"); strcopy(sC2,c2Len,"#d09f20"); }
    else if (iMMR >=  650) { strcopy(sRango,rLen,"plata");    strcopy(sC1,c1Len,"#c8d4e2"); strcopy(sC2,c2Len,"#98a4b2"); }
    else if (iMMR >=  500) { strcopy(sRango,rLen,"bronce");   strcopy(sC1,c1Len,"#e0954a"); strcopy(sC2,c2Len,"#b07030"); }
    else                   { strcopy(sRango,rLen,"hierro");   strcopy(sC1,c1Len,"#5a6570"); strcopy(sC2,c2Len,"#3a4550"); }
}

void ObtenerNombreMapaWeb(const char[] sMapa, char[] sOut, int iMaxLen)
{
    strcopy(sOut, iMaxLen, sMapa);
    // Quitar sufijo (SIM)
    int iSim = StrContains(sOut, " (SIM)");
    if (iSim >= 0) sOut[iSim] = '\0';

    if      (StrEqual(sOut,"c1m1_hotel"))           strcopy(sOut,iMaxLen,"Dead Center 1");
    else if (StrEqual(sOut,"c1m2_streets"))          strcopy(sOut,iMaxLen,"Dead Center 2");
    else if (StrEqual(sOut,"c1m3_mall"))             strcopy(sOut,iMaxLen,"Dead Center 3");
    else if (StrEqual(sOut,"c1m4_atrium"))           strcopy(sOut,iMaxLen,"Dead Center 4");
    else if (StrEqual(sOut,"c2m1_highway"))          strcopy(sOut,iMaxLen,"Dark Carnival 1");
    else if (StrEqual(sOut,"c2m2_fairgrounds"))      strcopy(sOut,iMaxLen,"Dark Carnival 2");
    else if (StrEqual(sOut,"c2m3_coaster"))          strcopy(sOut,iMaxLen,"Dark Carnival 3");
    else if (StrEqual(sOut,"c2m4_barns"))            strcopy(sOut,iMaxLen,"Dark Carnival 4");
    else if (StrEqual(sOut,"c2m5_concert"))          strcopy(sOut,iMaxLen,"Dark Carnival 5");
    else if (StrEqual(sOut,"c3m1_plankcountry"))     strcopy(sOut,iMaxLen,"Swamp Fever 1");
    else if (StrEqual(sOut,"c3m4_plantation"))       strcopy(sOut,iMaxLen,"Swamp Fever 4");
    else if (StrEqual(sOut,"c4m5_milltown_escape"))  strcopy(sOut,iMaxLen,"Hard Rain 5");
    else if (StrEqual(sOut,"c5m5_bridge"))           strcopy(sOut,iMaxLen,"The Parish 5");
    else if (StrEqual(sOut,"c8m5_rooftop"))          strcopy(sOut,iMaxLen,"No Mercy 5");
    else if (StrEqual(sOut,"c10m5_houseboat"))       strcopy(sOut,iMaxLen,"Cold Stream 5");
    else if (StrEqual(sOut,"c11m5_runway"))          strcopy(sOut,iMaxLen,"Dead Air 5");
    else if (StrEqual(sOut,"c12m5_cornfield"))       strcopy(sOut,iMaxLen,"Blood Harvest 5");
    else
    {
        // Fallback: reemplazar _ con espacios
        for (int i = 0; sOut[i] != '\0'; i++)
            if (sOut[i] == '_') sOut[i] = ' ';
    }
}

void GenerarRankingRowsWeb(char[] sOut, int iMaxLen)
{
    sOut[0] = '\0';
    if (g_DB == null)
    {
        strcopy(sOut, iMaxLen, "<tr><td colspan='5' class='empty'>Sin jugadores.</td></tr>");
        return;
    }

    DBResultSet rs = SQL_Query(g_DB,
        "SELECT nombre, mmr, wins, losses FROM mmr_players \
         WHERE steamid NOT LIKE 'STEAM_SIM%' AND (wins+losses)>0 \
         ORDER BY mmr DESC LIMIT 50");
    if (rs == null) return;

    int iPos = 0, iLiderMMR = -1;
    char sRow[768], sTmp[256];

    while (rs.FetchRow())
    {
        iPos++;
        char sNombre[64]; rs.FetchString(0, sNombre, sizeof(sNombre));
        int  iMMR = rs.FetchInt(1);
        int  iW   = rs.FetchInt(2);
        int  iL   = rs.FetchInt(3);
        if (iLiderMMR < 0) iLiderMMR = iMMR;

        char sRango[16], sC1[16], sC2[16];
        ObtenerRangoWebColors(iMMR, sRango, sizeof(sRango), sC1, sizeof(sC1), sC2, sizeof(sC2));

        char sRowClass[4];
        if      (iPos == 1) strcopy(sRowClass, sizeof(sRowClass), "r1");
        else if (iPos == 2) strcopy(sRowClass, sizeof(sRowClass), "r2");
        else if (iPos == 3) strcopy(sRowClass, sizeof(sRowClass), "r3");
        else                sRowClass[0] = '\0';

        int iTotal = iW + iL;
        int iWR    = (iTotal > 0) ? (iW * 100 / iTotal) : 0;

        char sGap[128];
        if (iPos == 1) strcopy(sGap, sizeof(sGap), "<div class=\"cima\">CIMA</div>");
        else Format(sGap, sizeof(sGap),
            "<div class=\"gapn\">%d</div><div class=\"gapl\">SR</div>", iMMR - iLiderMMR);

        sRow[0] = '\0';
        Format(sTmp, sizeof(sTmp), "<tr class=\"%s\"><td class=\"pos tl-%s\">", sRowClass, sRango);
        StrCat(sRow, sizeof(sRow), sTmp);
        Format(sTmp, sizeof(sTmp), "<div class=\"posn\">%d</div></td>", iPos);
        StrCat(sRow, sizeof(sRow), sTmp);
        Format(sTmp, sizeof(sTmp), "<td class=\"who\"><div class=\"nm\">%s</div>", sNombre);
        StrCat(sRow, sizeof(sRow), sTmp);
        Format(sTmp, sizeof(sTmp),
            "<div class=\"wl\"><span class=\"w\">%dW</span><span class=\"sep\">\xC2\xB7</span><span class=\"l\">%dL</span></div></td>",
            iW, iL);
        StrCat(sRow, sizeof(sRow), sTmp);
        Format(sTmp, sizeof(sTmp),
            "<td class=\"mmr\"><div class=\"chv\"><div class=\"band\" style=\"background:%s\"></div>", sC1);
        StrCat(sRow, sizeof(sRow), sTmp);
        Format(sTmp, sizeof(sTmp),
            "<div class=\"half\" style=\"background:%s\"></div>", sC2);
        StrCat(sRow, sizeof(sRow), sTmp);
        StrCat(sRow, sizeof(sRow), "<div class=\"nt\"></div><div class=\"bl\"></div><div class=\"br\"></div>");
        Format(sTmp, sizeof(sTmp), "<div class=\"num\">%d</div></div></td>", iMMR);
        StrCat(sRow, sizeof(sRow), sTmp);
        Format(sTmp, sizeof(sTmp),
            "<td class=\"wr\"><div class=\"wrn %s\">%d%%</div><div class=\"wrl\">W Rate</div></td>",
            iWR >= 50 ? "hi" : "lo", iWR);
        StrCat(sRow, sizeof(sRow), sTmp);
        Format(sTmp, sizeof(sTmp), "<td class=\"gap\">%s</td></tr>", sGap);
        StrCat(sRow, sizeof(sRow), sTmp);

        StrCat(sOut, iMaxLen, sRow);
    }
    delete rs;

    if (iPos == 0)
        strcopy(sOut, iMaxLen,
            "<tr><td colspan='5' class='empty'>Sin jugadores registrados todavia.</td></tr>");
}

void GenerarPartidasWeb(char[] sOut, int iMaxLen)
{
    sOut[0] = '\0';
    if (g_DB == null)
    {
        strcopy(sOut, iMaxLen, "<div class=\"empty\">Sin partidas.</div>");
        return;
    }

    DBResultSet rs = SQL_Query(g_DB,
        "SELECT id, fecha, mapa, puntos_grupo1, puntos_grupo2, ganador_grupo, modo \
         FROM mmr_partidas \
         WHERE modo NOT IN ('debug') AND mapa NOT LIKE '%(SIM)%' \
         ORDER BY fecha DESC LIMIT 20");
    if (rs == null) return;

    int iCount = 0;
    char sCard[1024], sTmp[256];

    while (rs.FetchRow())
    {
        iCount++;
        int  iId      = rs.FetchInt(0);
        int  iFecha   = rs.FetchInt(1);
        char sMapa[64]; rs.FetchString(2, sMapa, sizeof(sMapa));
        int  iPts1    = rs.FetchInt(3);
        int  iPts2    = rs.FetchInt(4);
        int  iGanador = rs.FetchInt(5);
        char sModo[8];  rs.FetchString(6, sModo, sizeof(sModo));

        char sFecha[32];
        FormatTime(sFecha, sizeof(sFecha), "%d/%m/%Y %H:%M", iFecha - 18000); // UTC-5 Lima

        char sMapaNombre[64];
        ObtenerNombreMapaWeb(sMapa, sMapaNombre, sizeof(sMapaNombre));

        // Jugadores por grupo
        char sG1[192], sG2[192];
        sG1[0] = '\0'; sG2[0] = '\0';
        bool bG1First = true, bG2First = true;
        char sQJug[128];
        Format(sQJug, sizeof(sQJug),
            "SELECT nombre, grupo FROM mmr_partida_jugadores WHERE partida_id=%d ORDER BY grupo", iId);
        DBResultSet rsJ = SQL_Query(g_DB, sQJug);
        if (rsJ != null)
        {
            while (rsJ.FetchRow())
            {
                char sNom[64]; rsJ.FetchString(0, sNom, sizeof(sNom));
                int  iGrp = rsJ.FetchInt(1);
                if (iGrp == 1) { if (!bG1First) StrCat(sG1,sizeof(sG1),", "); StrCat(sG1,sizeof(sG1),sNom); bG1First=false; }
                else           { if (!bG2First) StrCat(sG2,sizeof(sG2),", "); StrCat(sG2,sizeof(sG2),sNom); bG2First=false; }
            }
            delete rsJ;
        }
        if (sG1[0]=='\0') strcopy(sG1,sizeof(sG1),"—");
        if (sG2[0]=='\0') strcopy(sG2,sizeof(sG2),"—");

        char sModoUp[32];
        if      (StrEqual(sModo,"4v4"))   strcopy(sModoUp,sizeof(sModoUp),"4V4");
        else if (StrEqual(sModo,"1v1"))   strcopy(sModoUp,sizeof(sModoUp),"1V1");
        else if (StrEqual(sModo,"ab4v4")) strcopy(sModoUp,sizeof(sModoUp),"4V4 \xC2\xB7 ABANDONO");
        else if (StrEqual(sModo,"ab1v1")) strcopy(sModoUp,sizeof(sModoUp),"1V1 \xC2\xB7 ABANDONO");
        else                              strcopy(sModoUp,sizeof(sModoUp),sModo);

        sCard[0] = '\0';
        StrCat(sCard, sizeof(sCard), "<div class=\"pa\">");
        Format(sTmp, sizeof(sTmp),
            "<div class=\"ph\"><span class=\"pf\">%s</span><span class=\"pm\">%s \xC2\xB7 %s</span></div>",
            sMapaNombre, sFecha, sModoUp);
        StrCat(sCard, sizeof(sCard), sTmp);
        StrCat(sCard, sizeof(sCard), "<table class=\"pg\"><tr>");

        // G1
        Format(sTmp, sizeof(sTmp), "<td class=\"%s\"><div class=\"gt\">GRUPO 1%s</div>",
            iGanador==1 ? "gc gw" : "gc", iGanador==1 ? " \xE2\x9C\x93" : "");
        StrCat(sCard, sizeof(sCard), sTmp);
        Format(sTmp, sizeof(sTmp), "<div class=\"gp\">%d pts</div><div class=\"gj\">%s</div></td>", iPts1, sG1);
        StrCat(sCard, sizeof(sCard), sTmp);
        StrCat(sCard, sizeof(sCard), "<td class=\"gv\">VS</td>");

        // G2
        Format(sTmp, sizeof(sTmp), "<td class=\"%s\"><div class=\"gt\">GRUPO 2%s</div>",
            iGanador==2 ? "gc gw" : "gc", iGanador==2 ? " \xE2\x9C\x93" : "");
        StrCat(sCard, sizeof(sCard), sTmp);
        Format(sTmp, sizeof(sTmp), "<div class=\"gp\">%d pts</div><div class=\"gj\">%s</div></td>", iPts2, sG2);
        StrCat(sCard, sizeof(sCard), sTmp);

        StrCat(sCard, sizeof(sCard), "</tr></table></div>");
        StrCat(sOut, iMaxLen, sCard);
    }
    delete rs;

    if (iCount == 0)
        strcopy(sOut, iMaxLen, "<div class=\"empty\">Sin partidas registradas todavia.</div>");
}

public Action Timer_GenerarIndexHTML(Handle timer)
{
    if (!g_cvWebScript.BoolValue || g_DB == null) return Plugin_Stop;

    // Rutas dentro de SourceMod (siempre accesibles):
    // Template: addons/sourcemod/data/mmr_template.html
    // Output:   addons/sourcemod/data/mmr_index.html
    // El watcher.py monitorea mmr_index.html y lo copia a clubcampestre/index.html
    char sTemplatePath[PLATFORM_MAX_PATH];
    char sIndexPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sTemplatePath, sizeof(sTemplatePath), "data/mmr_template.html");
    BuildPath(Path_SM, sIndexPath,    sizeof(sIndexPath),    "data/mmr_index.html");

    File fTmpl = OpenFile(sTemplatePath, "r");
    if (fTmpl == null)
    {
        LogError("[SR] Web: template no encontrado en %s", sTemplatePath);
        LogError("[SR] Web: copia el motd_template.html a esa ruta.");
        return Plugin_Stop;
    }
    g_sWebHtml[0] = '\0';
    char sLine[1024];
    while (fTmpl.ReadLine(sLine, sizeof(sLine)))
        StrCat(g_sWebHtml, sizeof(g_sWebHtml), sLine);
    delete fTmpl;

    // 2. {LAST_UPDATE} — hora Lima (UTC-5)
    char sTimestamp[32];
    FormatTime(sTimestamp, sizeof(sTimestamp), "%d/%m/%Y %H:%M", GetTime() - 18000);
    ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{LAST_UPDATE}", sTimestamp);

    // 3. {RANKING_ROWS}
    GenerarRankingRowsWeb(g_sWebRanking, sizeof(g_sWebRanking));
    ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{RANKING_ROWS}", g_sWebRanking);

    // 4. {PARTIDAS_RECIENTES}
    GenerarPartidasWeb(g_sWebPartidas, sizeof(g_sWebPartidas));
    ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{PARTIDAS_RECIENTES}", g_sWebPartidas);

    // 5. Escribir mmr_index.html en la carpeta de SM data
    File fIndex = OpenFile(sIndexPath, "w");
    if (fIndex == null)
    {
        LogError("[SR] Web: no se pudo escribir index.html en %s", sIndexPath);
        return Plugin_Stop;
    }
    fIndex.WriteString(g_sWebHtml, false);
    delete fIndex;

    LogMessage("[SR] Web: index.html generado (%d chars) -> %s",
        strlen(g_sWebHtml), sIndexPath);
    return Plugin_Stop;

    // El MOTD se regenera automaticamente desde cl4d2_mmr_motd.smx via MMR_OnGameEnd forward
}

public Action Cmd_WebGenerar(int client, int args)
{
    if (g_DB == null)
    {
        ReplyToCommand(client, "[SR] Web: la DB no esta conectada.");
        return Plugin_Handled;
    }

    char sTemplatePath[PLATFORM_MAX_PATH];
    char sIndexPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sTemplatePath, sizeof(sTemplatePath), "data/mmr_template.html");
    BuildPath(Path_SM, sIndexPath,    sizeof(sIndexPath),    "data/mmr_index.html");

    ReplyToCommand(client, "[SR] Web: generando...");
    ReplyToCommand(client, "[SR] Web: template = %s", sTemplatePath);
    ReplyToCommand(client, "[SR] Web: output   = %s", sIndexPath);

    // Verificar que el template existe
    File fTest = OpenFile(sTemplatePath, "r");
    if (fTest == null)
    {
        ReplyToCommand(client, "[SR] Web: ERROR - template no encontrado.");
        ReplyToCommand(client, "[SR] Web: Copia motd_template.html a: %s", sTemplatePath);
        return Plugin_Handled;
    }
    delete fTest;

    // Generar directamente (misma logica que Timer_GenerarIndexHTML)
    g_sWebHtml[0] = '\0';
    File fTmpl = OpenFile(sTemplatePath, "r");
    char sLine[1024];
    while (fTmpl.ReadLine(sLine, sizeof(sLine)))
        StrCat(g_sWebHtml, sizeof(g_sWebHtml), sLine);
    delete fTmpl;

    char sTimestamp[32];
    FormatTime(sTimestamp, sizeof(sTimestamp), "%d/%m/%Y %H:%M", GetTime() - 18000);
    ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{LAST_UPDATE}", sTimestamp);

    GenerarRankingRowsWeb(g_sWebRanking, sizeof(g_sWebRanking));
    ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{RANKING_ROWS}", g_sWebRanking);

    GenerarPartidasWeb(g_sWebPartidas, sizeof(g_sWebPartidas));
    ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{PARTIDAS_RECIENTES}", g_sWebPartidas);

    File fIndex = OpenFile(sIndexPath, "w");
    if (fIndex == null)
    {
        ReplyToCommand(client, "[SR] Web: ERROR - no se pudo escribir index.html. Verifica sm_mmr_index_path");
        return Plugin_Handled;
    }
    fIndex.WriteString(g_sWebHtml, false);
    delete fIndex;

    ReplyToCommand(client, "[SR] Web: index.html generado OK (%d chars). El watcher lo subira a GitHub en segundos.", strlen(g_sWebHtml));
    LogMessage("[SR] Web: index.html generado manualmente por %N (%d chars).", client, strlen(g_sWebHtml));
    return Plugin_Handled;
}

// =========================================================================
// HUD - Panel estilo ZoneMod (izquierda-centro). Cada jugador ve el suyo.
//   Lineas blancas  = DrawText (con sangria g_cvHudPad para alinear)
//   Lineas naranjas = DrawItem (el juego les pone "N." delante)
//   Se reenvia cada 1 seg mientras dure, igual que el Tank HUD.
// =========================================================================

void HudNuevo(int client)
{
    g_iHudLineas[client]  = 0;
    g_bHudSinItems[client] = false;
}

void HudAgregar(int client, const char[] sTexto, bool bNaranja, bool bSangria)
{
    if (g_iHudLineas[client] >= HUD_MAX_LINEAS) return;
    int n = g_iHudLineas[client]++;
    g_sHudLinea[client][n][0] = '\0';
    if (bSangria)
    {
        int iPad = g_cvHudPad.IntValue;
        for (int k = 0; k < iPad; k++) StrCat(g_sHudLinea[client][n], HUD_LARGO_LINEA, " ");
    }
    StrCat(g_sHudLinea[client][n], HUD_LARGO_LINEA, sTexto);
    g_bHudNaranja[client][n] = bNaranja;
}

void HudTitulo(int client, const char[] sTexto)  { HudAgregar(client, sTexto, false, false); }
void HudTexto(int client, const char[] sTexto)   { HudAgregar(client, sTexto, false, true);  }
void HudNaranja(int client, const char[] sTexto) { HudAgregar(client, sTexto, true,  false); }

void HudCabecera(int client, const char[] sTitulo)
{
    HudNuevo(client);
    HudTitulo(client, sTitulo);
    HudTitulo(client, "___________________________");
}

void HudMostrar(int client, int iSegundos)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;
    g_iHudResta[client] = iSegundos;
    HudDibujar(client);
    if (g_hHudTimer[client] == null)
        g_hHudTimer[client] = CreateTimer(1.0, Timer_Hud, GetClientUserId(client), TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void HudDibujar(int client)
{
    if (EnPausa()) return;   // en pausa solo se ve el menu de pausa
    Panel panel = new Panel();
    char sTmp[HUD_LARGO_LINEA + 16];
    int iPad = g_cvHudPad.IntValue;

    for (int i = 0; i < g_iHudLineas[client]; i++)
    {
        if (g_bHudNaranja[client][i] && !g_bHudSinItems[client])
        {
            panel.DrawItem(g_sHudLinea[client][i]);
        }
        else if (g_bHudNaranja[client][i])
        {
            // naranja dibujada en blanco: agregar sangria para que siga alineada
            sTmp[0] = '\0';
            for (int k = 0; k < iPad; k++) StrCat(sTmp, sizeof(sTmp), " ");
            StrCat(sTmp, sizeof(sTmp), g_sHudLinea[client][i]);
            panel.DrawText(sTmp);
        }
        else
        {
            panel.DrawText(g_sHudLinea[client][i]);
        }
    }
    panel.Send(client, PanelHandler_Nada, 2);
    delete panel;
}

public int PanelHandler_Nada(Menu menu, MenuAction action, int param1, int param2)
{
    return 0;   // panel informativo
}

public Action Timer_Hud(Handle timer, int userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client)) return Plugin_Stop;

    if (g_hHudTimer[client] != timer) return Plugin_Stop;   // timer viejo (slot reusado)

    // panel de la rotacion pero la rotacion ya termino (salieron del refugio)
    if (g_bHudSinItems[client] && g_hRotar == null)
    {
        g_hHudTimer[client] = null;
        HudCerrar(client);
        return Plugin_Stop;
    }

    g_iHudResta[client]--;
    if (g_iHudResta[client] <= 0)
    {
        g_hHudTimer[client] = null;
        return Plugin_Stop;
    }
    HudDibujar(client);
    return Plugin_Continue;
}

// Cierra el panel de un jugador
void HudCerrar(int client)
{
    g_iHudResta[client] = 0;
    if (!IsClientInGame(client) || IsFakeClient(client)) return;
    if (EnPausa()) return;   // no tapar el menu de pausa
    Panel panel = new Panel();
    panel.DrawText(" ");
    panel.Send(client, PanelHandler_Nada, 1);
    delete panel;
}

// ─── Formato de lineas ───

// Recorta un nombre a iMax caracteres (respeta tildes/emoji UTF-8) y agrega ".."
void RecortarNombre(const char[] sNombre, char[] sOut, int iLen, int iMax)
{
    int iChars = 0, i = 0;
    while (sNombre[i] != '\0')
    {
        if ((sNombre[i] & 0xC0) != 0x80)   // inicio de caracter UTF-8
        {
            if (iChars == iMax) break;
            iChars++;
        }
        i++;
    }
    if (sNombre[i] == '\0') { strcopy(sOut, iLen, sNombre); return; }
    int iCopiar = (i + 1 < iLen - 2) ? i + 1 : iLen - 2;
    strcopy(sOut, iCopiar, sNombre);
    StrCat(sOut, iLen, "..");
}

// Rellena con espacios a la izquierda (numeros alineados a la derecha)
void Rellenar(char[] sBuf, int iLen, const char[] sTexto, int iAncho)
{
    char sPad[32];
    sPad[0] = '\0';
    for (int k = strlen(sTexto); k < iAncho && k < 30; k++) StrCat(sPad, sizeof(sPad), " ");
    Format(sBuf, iLen, "%s%s", sPad, sTexto);
}

// "+42     542   Nombre"
void LineaResultado(char[] sOut, int iLen, int iDiff, int iMMR, const char[] sNombre)
{
    char sDiff[16], sMMR[16], sD[48], sM[48], sNom[MAX_NAME_LENGTH];
    Format(sDiff, sizeof(sDiff), "%s%d", iDiff >= 0 ? "+" : "", iDiff);
    IntToString(iMMR, sMMR, sizeof(sMMR));
    Rellenar(sD, sizeof(sD), sDiff, 4);
    Rellenar(sM, sizeof(sM), sMMR, 5);
    RecortarNombre(sNombre, sNom, sizeof(sNom), HUD_NOMBRE_MAX);
    Format(sOut, iLen, "%s   %s   %s", sD, sM, sNom);
}

// "#1    3800   13W/7L   Nombre"
void LineaTop(char[] sOut, int iLen, int iPos, int iMMR, int iW, int iL, const char[] sNombre)
{
    char sPos[8], sMMR[16], sWL[24], sP[32], sM[48], sR[48], sNom[MAX_NAME_LENGTH];
    Format(sPos, sizeof(sPos), "#%d", iPos);
    IntToString(iMMR, sMMR, sizeof(sMMR));
    Format(sWL, sizeof(sWL), "%dW/%dL", iW, iL);
    Rellenar(sP, sizeof(sP), sPos, 3);
    Rellenar(sM, sizeof(sM), sMMR, 5);
    Rellenar(sR, sizeof(sR), sWL, 8);
    RecortarNombre(sNombre, sNom, sizeof(sNom), HUD_NOMBRE_MAX);
    Format(sOut, iLen, "%s   %s   %s   %s", sP, sM, sR, sNom);
}

// ─── Paneles simples ───

void PanelAviso(int client, const char[] sTitulo, const char[] sTexto)
{
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client)) return;
    HudCabecera(client, sTitulo);
    HudTexto(client, sTexto);
    HudMostrar(client, 5);
}

void PanelJugador(int client, const char[] sTitulo, const char[] sNombre, int iMMR, int iW, int iL)
{
    char sRango[32], sColor[8], sLinea[HUD_LARGO_LINEA], sNom[MAX_NAME_LENGTH];
    ObtenerRango(iMMR, sRango, sizeof(sRango), sColor, sizeof(sColor));
    int iPartidas = iW + iL;
    float fWR = (iPartidas > 0) ? float(iW) / float(iPartidas) * 100.0 : 0.0;

    HudCabecera(client, sTitulo);
    RecortarNombre(sNombre, sNom, sizeof(sNom), HUD_NOMBRE_MAX);
    HudNaranja(client, sNom);
    Format(sLinea, sizeof(sLinea), "Rango:      %s", sRango);      HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "SR:         %d", iMMR);        HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Partidas:   %d", iPartidas);   HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Victorias:  %d", iW);          HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Derrotas:   %d", iL);          HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Winrate:    %.1f%%", fWR);     HudTexto(client, sLinea);
    HudMostrar(client, g_cvHudSegCmd.IntValue);
}

// !mmr (lo usa el comando y la rotacion)
void ArmarPanelMMR(int client)
{
    HudCabecera(client, "ClubCampestre :: Mi SR");

    char sNombre[MAX_NAME_LENGTH], sNom[MAX_NAME_LENGTH];
    GetClientName(client, sNombre, sizeof(sNombre));
    RecortarNombre(sNombre, sNom, sizeof(sNom), HUD_NOMBRE_MAX);
    HudNaranja(client, sNom);

    if (!g_bLoaded[client])
    {
        HudTexto(client, "Cargando datos...");
        return;
    }

    char sRango[32], sColor[8], sLinea[HUD_LARGO_LINEA];
    ObtenerRango(g_iMMR[client], sRango, sizeof(sRango), sColor, sizeof(sColor));
    int iPartidas = g_iWins[client] + g_iLosses[client];
    float fWR = (iPartidas > 0) ? float(g_iWins[client]) / float(iPartidas) * 100.0 : 0.0;

    Format(sLinea, sizeof(sLinea), "Rango:      %s", sRango);
    HudTexto(client, sLinea);
    if (g_iRank[client] > 0) Format(sLinea, sizeof(sLinea), "SR:         %d   (#%d)", g_iMMR[client], g_iRank[client]);
    else                     Format(sLinea, sizeof(sLinea), "SR:         %d", g_iMMR[client]);
    HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Partidas:   %d", iPartidas);          HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Victorias:  %d", g_iWins[client]);    HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Derrotas:   %d", g_iLosses[client]);  HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Winrate:    %.1f%%", fWR);            HudTexto(client, sLinea);
}

// Guarda el resultado de la consulta del top (nombre, mmr, wins, losses, steamid)
void GuardarTopCache(DBResultSet results)
{
    g_iTopCnt = 0;
    while (g_iTopCnt < TOP_LIMITE && results.FetchRow())
    {
        int n = g_iTopCnt++;
        results.FetchString(0, g_sTopNom[n], MAX_NAME_LENGTH);
        if (g_sTopNom[n][0] == '\0') strcopy(g_sTopNom[n], MAX_NAME_LENGTH, "Desconocido");
        g_iTopMMR[n] = results.FetchInt(1);
        g_iTopW[n]   = results.FetchInt(2);
        g_iTopL[n]   = results.FetchInt(3);
        results.FetchString(4, g_sTopSteam[n], sizeof(g_sTopSteam[]));
    }
}

// !top (lo usa el comando y la rotacion). Tu puesto sale en naranja.
void ArmarPanelTop(int client)
{
    HudCabecera(client, "ClubCampestre :: Top 10 SR");

    if (g_iTopCnt == 0)
    {
        HudTexto(client, "Sin datos todavia.");
        return;
    }

    char sMiSteam[32] = "";
    GetClientAuthId(client, AuthId_Steam2, sMiSteam, sizeof(sMiSteam));

    char sLinea[HUD_LARGO_LINEA];
    for (int i = 0; i < g_iTopCnt; i++)
    {
        LineaTop(sLinea, sizeof(sLinea), i + 1, g_iTopMMR[i], g_iTopW[i], g_iTopL[i], g_sTopNom[i]);
        if (sMiSteam[0] != '\0' && StrEqual(g_sTopSteam[i], sMiSteam)) HudNaranja(client, sLinea);
        else                                                          HudTexto(client, sLinea);
    }
}

// ─── Fin de campaña ───

void ArmarPanelFin(int client)
{
    HudCabecera(client, g_bFin1v1 ? "ClubCampestre :: SR 1v1" : "ClubCampestre :: SR");

    char sLinea[HUD_LARGO_LINEA];
    for (int paso = 0; paso < 2; paso++)
    {
        // primero el equipo ganador, despues el perdedor
        int e = (paso == 0) ? g_iFinGanador : 1 - g_iFinGanador;
        if (paso == 1 && g_iFinCnt[e] == 0) break;   // abandono: el otro equipo ya no esta
        if (paso == 1) HudTitulo(client, " ");
        if (paso == 0) HudNaranja(client, g_bFinAbandono ? "VICTORIA POR ABANDONO" : "VICTORIA");
        else           HudNaranja(client, "DERROTA");

        for (int k = 0; k < g_iFinCnt[e]; k++)
        {
            LineaResultado(sLinea, sizeof(sLinea), g_iFinDiff[e][k], g_iFinMMR[e][k], g_sFinNom[e][k]);
            if (g_iFinCli[e][k] == client) HudNaranja(client, sLinea);   // tu linea
            else                           HudTexto(client, sLinea);
        }
    }
}

void MostrarFinATodos()
{
    if (g_iFinGanador < 0 || g_iFinGanador > 1) return;
    PararRotacion();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        ArmarPanelFin(i);
        HudMostrar(i, g_cvHudSegFin.IntValue);
    }
}

void MostrarEmpateATodos()
{
    PararRotacion();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        HudCabecera(i, "ClubCampestre :: SR");
        HudNaranja(i, "EMPATE");
        HudTexto(i, "No se modifica el SR.");
        HudMostrar(i, 15);
    }
}

// ─── Secuencia al iniciar la ronda: Top 10 (10 s) -> tu SR (10 s) -> desaparece ───
// Todo en blanco (sin items) para que las teclas 1-9 sigan cambiando de arma.
// Si se pausa en medio, se reinicia desde el Top 10 al reanudar.

public Action Timer_IniciarRotacion(Handle timer)
{
    IniciarRotacion();
    return Plugin_Stop;
}

public Action Cmd_Rotar(int client, int args)
{
    if (g_hRotar != null) { PararRotacion();   ReplyToCommand(client, "[SR] Secuencia quitada."); }
    else                  { IniciarRotacion(); ReplyToCommand(client, "[SR] Secuencia: Top 10 -> tu SR."); }
    return Plugin_Handled;
}

void IniciarRotacion()
{
    if (g_hRotar != null || g_DB == null) return;
    if (YaSalieron()) return;   // si salieron antes de los 3 seg, no empezar

    // Refrescar el top y el puesto de cada jugador (asincrono)
    SQL_TQuery(g_DB, Callback_TopCache,
        "SELECT nombre, mmr, wins, losses, steamid FROM mmr_players \
         WHERE (wins + losses) >= 1 ORDER BY mmr DESC LIMIT 10;");
    for (int i = 1; i <= MaxClients; i++)
        if (IsValidHuman(i)) PedirRank(i);

    // Se muestra en el proximo segundo (da tiempo a que lleguen el top y los puestos)
    g_iRotarPaso    = 0;
    g_bSecReiniciar = true;
    g_hRotar = CreateTimer(1.0, Timer_Rotar, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void PararRotacion()
{
    if (g_hRotar != null)
    {
        Handle h = g_hRotar;
        g_hRotar = null;
        KillTimer(h);
    }
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (g_bHudSinItems[i]) HudCerrar(i);   // solo cierra los paneles de la rotacion
    }
}

public Action Timer_Rotar(Handle timer)
{
    if (YaSalieron())
    {
        g_hRotar = null;          // este timer termina solo (no KillTimer sobre si mismo)
        PararRotacion();          // cierra los paneles
        return Plugin_Stop;
    }

    // En pausa: no mostrar nada; al reanudar empieza de nuevo desde el Top 10
    if (EnPausa())
    {
        g_bSecReiniciar = true;
        return Plugin_Continue;
    }

    if (g_bSecReiniciar)
    {
        g_bSecReiniciar = false;
        g_iRotarPaso = 0;
        g_iSecSeg = g_cvHudSegRotar.IntValue;
        MostrarRotacion();
        return Plugin_Continue;
    }

    g_iSecSeg--;
    if (g_iSecSeg > 0) return Plugin_Continue;

    if (g_iRotarPaso == 0)
    {
        g_iRotarPaso = 1;                      // ahora tu SR
        g_iSecSeg = g_cvHudSegRotar.IntValue;
        MostrarRotacion();
        return Plugin_Continue;
    }

    // Termino: Top 10 y tu SR ya se mostraron
    g_hRotar = null;
    PararRotacion();
    return Plugin_Stop;
}

void MostrarRotacion()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (g_iRotarPaso == 0) ArmarPanelTop(i);
        else                   ArmarPanelMMR(i);
        g_bHudSinItems[i] = true;
        HudMostrar(i, g_cvHudSegRotar.IntValue + 1);   // el timer de la secuencia la cierra
    }
}

public void Callback_TopCache(Database db, DBResultSet results, const char[] sError, any data)
{
    if (results == null || sError[0] != '\0') return;
    GuardarTopCache(results);
}

void PedirRank(int client)
{
    char sSteam[64], sEsc[128], sQuery[256];
    if (!GetClientAuthId(client, AuthId_Steam2, sSteam, sizeof(sSteam))) return;
    SQL_EscapeString(g_DB, sSteam, sEsc, sizeof(sEsc));
    Format(sQuery, sizeof(sQuery),
        "SELECT COUNT(*)+1 FROM mmr_players WHERE mmr > (SELECT mmr FROM mmr_players WHERE steamid='%s');", sEsc);
    SQL_TQuery(g_DB, Callback_RankCache, sQuery, GetClientUserId(client));
}

public void Callback_RankCache(Database db, DBResultSet results, const char[] sError, any userid)
{
    int client = GetClientOfUserId(userid);
    if (client == 0) return;
    if (results != null && sError[0] == '\0' && results.FetchRow())
        g_iRank[client] = results.FetchInt(0);
}
