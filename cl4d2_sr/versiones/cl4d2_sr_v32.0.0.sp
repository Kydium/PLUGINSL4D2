/**
 * L4D2 SR System - ClubCampestre   (archivo: cl4d2_sr.sp)
 * Version 32.0.0 - SIMPLE + HUD (panel estilo ZoneMod) + castigo por salida y abandono
 *
 * v32 - Registro de la campaña:
 *   - Cada mitad que termina, se anota en que equipo (A/B) jugo cada uno.
 *   - Resultado por partes si te cambiaron de equipo a mitad de campaña.
 *   - El que se va y no vuelve: derrota + castigo extra (interno, no sale en el panel).
 *   - Si un equipo entero se va (3 min sin nadie): el otro gana por abandono (50 %).
 *   - Si se van los dos equipos: anulada, sin castigos.
 *   - Rendicion (!rendirse en cl4d2_pausa): cualquier equipo, desde el 2do capitulo.
 *     Al equipo que pierde por sm_sr_rendirse_dif (500) le sale sola la votacion al
 *     empezar un capitulo. Si se aprueba: el otro equipo gana; resultado normal
 *     por partes para todos (los que se fueron antes igual llevan su castigo).
 *
 * Funcionamiento:
 *   Al terminar la campaña (2da mitad del mapa final), se mira quien gano
 *   (marcador de campaña). Cada jugador que jugo al menos 1 mitad:
 *     - si esta en el server: suma/resta segun las mitades que jugo en cada equipo
 *     - si se fue y no volvio: derrota + castigo (sm_sr_castigo_salida)
 *   Pasarse a espectador NO es irse: se le cuenta con su equipo.
 *   - Sin grupos ni rosters fijos: se anota en que equipo juega cada uno en cada mitad.
 *   - Si en toda la campaña hubo como maximo 1 jugador por lado -> tabla 1v1.
 *   - sm_sr_status muestra el registro (mitades por equipo, quien esta FUERA).
 *
 * Opciones v32 (cfg/sourcemod/l4d2_sr_system.cfg):
 *   sm_sr_castigo_salida  20   SR extra que pierde el que se va (ademas de la derrota)
 *   sm_sr_abandono_pct    50   % de una victoria para el equipo que se quedo
 *   sm_sr_abandono_espera 180  segundos sin nadie para declarar abandono
 *   sm_sr_min_mitades     1    mitades minimas para contar
 *   sm_sr_motd            1    motd.txt: 1 = abre la pagina de sm_sr_motd_url (diseño completo)
 *                              2 = version liviana desde data/sr_motd_template.html, 0 = no tocar
 *   sm_sr_motd_url        "http://clubcampestre.dpdns.org/"   pagina que abre el MOTD (http, no https)
 *
 * HUD (panel a la izquierda-centro, cada jugador ve el suyo, sin chat):
 *   - Fin de campaña: VICTORIA / DERROTA con los 2 equipos (tu linea en naranja).
 *   - !sr, !top, !sr_jugador, !sr1v1, !top1v1 salen en el panel.
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
#define DEFAULT_SR         500

// Umbrales de RANGOS por SR (iguales a los del MOTD)
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
    name        = "L4D2 SR System (ClubCampestre)",
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

    // Para el plugin de pausa/votaciones: !rendirse
    CreateNative("CL4D2_SR_PuedeRendirse", Native_PuedeRendirse);
    CreateNative("CL4D2_SR_Rendirse",      Native_Rendirse);
    CreateNative("CL4D2_SR_PanelRendicionPrueba", Native_PanelRendicionPrueba);
    CreateNative("CL4D2_SR_MostrarPanelFin", Native_MostrarPanelFin);
    CreateNative("CL4D2_SR_RemontadaImposible", Native_RemontadaImposible);
    RegPluginLibrary("cl4d2_sr");
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

int  g_iSR[MAXPLAYERS + 1];
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
ConVar g_cvRendirseDif;
ConVar g_cvRendirseAviso;
ConVar g_cvMotd;
ConVar g_cvMotdUrl;

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
int    g_iFinSR[2][MAXPLAYERS + 1];
char   g_sFinNom[2][MAXPLAYERS + 1][MAX_NAME_LENGTH];
int    g_iFinGanador = -1;
bool   g_bFin1v1 = false;
bool   g_bFinAbandono = false;
bool   g_bFinRendicion = false;
int    g_iLadoOcultarPanel = 0;   // rendicion: a este lado no se le muestra el panel todavia (primero elige campaña)

// Cache del top 10 (para !top y la rotacion)
int    g_iTopCnt = 0;
char   g_sTopNom[TOP_LIMITE][MAX_NAME_LENGTH];
char   g_sTopSteam[TOP_LIMITE][32];
int    g_iTopSR[TOP_LIMITE];
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
    g_cvEnabled   = CreateConVar("sm_sr_enable", DEFAULT_ENABLED,  "Activa/desactiva el sistema SR", FCVAR_NOTIFY);
    g_cvKFactor   = CreateConVar("sm_sr_k",      DEFAULT_K_FACTOR, "Factor K del calculo Elo", FCVAR_NOTIFY);
    g_cvDebugMode = CreateConVar("sm_sr_debug",  DEFAULT_DEBUG,    "1 = cuenta aunque un equipo no tenga humanos (para probar solo)", FCVAR_NOTIFY);
    g_cvWebScript = CreateConVar("sm_sr_web_script", "1", "1 = genera data/sr_index.html al terminar la campaña", FCVAR_NOTIFY);
    g_cvHudPad    = CreateConVar("sm_sr_hud_pad",   "4", "Espacios delante de las lineas blancas del panel (para alinear con las naranjas)", FCVAR_NOTIFY, true, 0.0, true, 10.0);
    g_cvHudRotar  = CreateConVar("sm_sr_hud_rotar", "0", "1 = al iniciar la ronda muestra a la izquierda el Top 10 y luego tu SR (una vez). 0 = desactivado", FCVAR_NOTIFY);
    g_cvHudSegFin   = CreateConVar("sm_sr_hud_seg_fin",   "30", "Segundos que se ve el panel de fin de campaña", FCVAR_NOTIFY, true, 1.0, true, 300.0);
    g_cvHudSegCmd   = CreateConVar("sm_sr_hud_seg_cmd",   "10", "Segundos que se ve !sr, !top, !sr_jugador, !sr1v1, !top1v1", FCVAR_NOTIFY, true, 1.0, true, 300.0);
    g_cvHudSegRotar = CreateConVar("sm_sr_hud_seg_inicio", "10", "Segundos de cada pantalla al iniciar la ronda (Top 10 y luego tu SR)", FCVAR_NOTIFY, true, 2.0, true, 60.0);

    g_cvCastigoSalida  = CreateConVar("sm_sr_castigo_salida",  "20",  "SR extra que pierde el que se sale y no vuelve (ademas de la derrota)", FCVAR_NOTIFY, true, 0.0, true, 500.0);
    g_cvAbandonoPct    = CreateConVar("sm_sr_abandono_pct",    "50",  "Porcentaje de una victoria normal que gana el equipo que se quedo si el otro abandona", FCVAR_NOTIFY, true, 0.0, true, 100.0);
    g_cvAbandonoEspera = CreateConVar("sm_sr_abandono_espera", "180", "Segundos que un equipo debe estar sin nadie para declarar abandono", FCVAR_NOTIFY, true, 30.0, true, 1800.0);
    g_cvMinMitades     = CreateConVar("sm_sr_min_mitades",     "1",   "Mitades minimas jugadas para contar en la campaña (y para el castigo por salida)", FCVAR_NOTIFY, true, 1.0, true, 20.0);

    g_cvRendirseDif   = CreateConVar("sm_sr_rendirse_dif",   "500", "Puntos que un equipo debe ir perdiendo para que le salga sola la votacion de rendirse al empezar un capitulo (0 = nunca)", FCVAR_NOTIFY, true, 0.0, true, 10000.0);
    g_cvRendirseAviso = CreateConVar("sm_sr_rendirse_aviso", "0",   "1 = ademas avisa por chat (la votacion automatica de rendirse esta en cl4d2_pausa)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    g_cvMotd = CreateConVar("sm_sr_motd", "1", "motd.txt: 1 = redirige a sm_sr_motd_url, 2 = version liviana (data/sr_motd_template.html), 0 = no tocar", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_cvMotdUrl = CreateConVar("sm_sr_motd_url", "http://clubcampestre.dpdns.org/", "Pagina que abre el MOTD (sm_sr_motd 1). Tiene que ser http:// (el MOTD no abre https).");

    AutoExecConfig(true, "l4d2_sr_system");

    RegConsoleCmd("sm_top",            Cmd_Top,         "Top 10 jugadores por SR");
    RegConsoleCmd("sm_sr",             Cmd_SR,         "Muestra tu SR, partidas y ranking global");
    RegConsoleCmd("sm_sr_jugador",     Cmd_SRJugador,  "SR de otro jugador: sm_sr_jugador <nombre>");
    RegConsoleCmd("sm_sr1v1",          Cmd_SR1v1,      "Muestra tu SR 1v1");
    RegConsoleCmd("sm_top1v1",         Cmd_Top1v1,      "Top 10 jugadores 1v1");

    RegAdminCmd("sm_setsr",           Cmd_SetSR,      ADMFLAG_GENERIC, "Ajusta SR: sm_setsr <target> <cantidad>");
    RegAdminCmd("sm_resetsr",         Cmd_ResetSR,    ADMFLAG_GENERIC, "Resetea SR a 500: sm_resetsr <target>");
    RegAdminCmd("sm_setsr1v1",        Cmd_SetSR1v1,   ADMFLAG_GENERIC, "Ajusta SR 1v1: sm_setsr1v1 <target> <cantidad>");
    RegAdminCmd("sm_resetsr1v1",      Cmd_ResetSR1v1, ADMFLAG_GENERIC, "Resetea SR 1v1 a 500: sm_resetsr1v1 <target>");
    RegAdminCmd("sm_sr_reload",       Cmd_ReloadSR,   ADMFLAG_GENERIC, "Recarga la DB y el SR de los jugadores");
    RegAdminCmd("sm_sr_status",       Cmd_StatusSR,   ADMFLAG_GENERIC, "Estado actual: equipos, puntaje y quien va ganando");
    RegAdminCmd("sm_sr_web",          Cmd_WebGenerar,  ADMFLAG_GENERIC, "Genera el index.html ahora mismo");
    RegAdminCmd("sm_sr_testhud",      Cmd_TestHud,     ADMFLAG_GENERIC, "Muestra el panel de fin de campaña con los jugadores actuales (datos de prueba, no guarda)");
    RegAdminCmd("sm_sr_rotar",        Cmd_Rotar,       ADMFLAG_GENERIC, "Muestra a mano la secuencia Top 10 -> tu SR (o la quita)");

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
    CreateTimer(8.0, Timer_GenerarMotd, _, TIMER_FLAG_NO_MAPCHANGE);
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
        else if (g_cvRendirseAviso.BoolValue)
            CreateTimer(15.0, Timer_AvisoRendirse, _, TIMER_FLAG_NO_MAPCHANGE);   // esperar a que carguen
    }
    return Plugin_Stop;
}

// Al empezar un capitulo nuevo: si un equipo va perdiendo por sm_sr_rendirse_dif o mas,
// se le avisa SOLO a ese equipo por chat que puede usar !rendirse.
public Action Timer_AvisoRendirse(Handle timer)
{
    if (!g_cvEnabled.BoolValue || g_bCampaniaCerrada || g_iMitadesTotales < 1) return Plugin_Stop;
    int iDifMin = g_cvRendirseDif.IntValue;
    if (iDifMin <= 0) return Plugin_Stop;

    int iScores[2];
    L4D2_GetVersusCampaignScores(iScores);
    int iDif = iScores[0] - iScores[1];
    if (iDif < 0) iDif = -iDif;
    if (iDif < iDifMin) return Plugin_Stop;

    int ePierde  = (iScores[0] < iScores[1]) ? 0 : 1;
    int iSurvIdx = IdxSurvivorsSegunJuego();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i) || EquipoCampania(i, iSurvIdx) != ePierde) continue;
        PrintToChat(i, "\x04[ClubCampestre]\x01 Tu equipo va perdiendo por \x05%d\x01 puntos. Si quieren, escriban \x04!rendirse\x01 o sigan jugando el capitulo.", iDif);
    }
    LogMessage("[SR] Aviso de rendicion al equipo %s (pierde por %d).", ePierde == 0 ? "A" : "B", iDif);
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
//     - Se fue y no volvio (jugo al menos sm_sr_min_mitades): derrota completa
//       + castigo extra (sm_sr_castigo_salida). Interno, no sale en el panel.
//   Abandono de equipo: si un lado se queda SIN NADIE conectado durante
//   sm_sr_abandono_espera segundos y el otro lado si tiene gente, la campaña
//   se cierra: los que se quedaron ganan sm_sr_abandono_pct % de una victoria.
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
void ProcesarResultado(int iGanador, int iAbandono, const int[] iScores, bool bRendicion = false)
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
        LeerSRPorSteamID(g_sRegSteam[r], iOld[r], iW[r], iL[r]);
        fSuma[iPrin[r]] += float(iOld[r]);
    }
    float fProm[2];
    for (int e = 0; e < 2; e++)
        fProm[e] = (nCont[e] > 0) ? fSuma[e] / float(nCont[e]) : float(DEFAULT_SR);

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
    g_bFinRendicion = bRendicion;

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
            GuardarSRPorSteamID(g_sRegSteam[r], iNew, w, l);

        if (bPresente)
        {
            int c = iCli[r];
            if (!g_bModoEs1v1)
            {
                g_iSR[c] = iNew; g_iWins[c] = w; g_iLosses[c] = l; g_bLoaded[c] = true;
            }
            // En el panel sale en el equipo donde esta ahora (o su equipo principal si es espectador)
            int eP = EquipoCampania(c, iSurvIdx);
            if (eP < 0) eP = iPrin[r];
            int f = g_iFinCnt[eP]++;
            g_iFinCli[eP][f]  = c;
            g_iFinDiff[eP][f] = iNew - iOld[r];
            g_iFinSR[eP][f]  = iNew;
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
    else if (bRendicion)                strcopy(sModo, sizeof(sModo), g_bModoEs1v1 ? "rn1v1" : "rn4v4");
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

public Action Cmd_StatusSR(int client, int args)
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

public Action Cmd_ReloadSR(int client, int args)
{
    if (g_DB == null) InitDatabase();
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        g_bLoaded[i] = false;
        LoadPlayerSR(i);
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
    g_iSR[client]    = DEFAULT_SR;
    g_iWins[client]   = 0;
    g_iLosses[client] = 0;
    LoadPlayerSR(client);
}

public void OnClientDisconnect(int client)
{
    // Todo se guarda en la DB en el momento: aca solo se limpia el slot.
    g_hHudTimer[client]  = null;   // el timer se corta solo (userid invalido)
    g_iHudLineas[client] = 0;
    g_iRank[client]      = 0;
    g_bLoaded[client] = false;
    g_iSR[client]    = DEFAULT_SR;
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

void LoadPlayerSR(int client)
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
    SQL_TQuery(g_DB, Callback_LoadSR, sQuery, dp);
}

public Action Timer_RetryLoad(Handle timer, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientConnected(client) || !IsValidHuman(client)) return Plugin_Stop;
    if (g_bLoaded[client]) return Plugin_Stop;
    LoadPlayerSR(client);
    return Plugin_Stop;
}

public void Callback_LoadSR(Database db, DBResultSet results, const char[] sError, DataPack dp)
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
        g_iSR[client]    = results.FetchInt(0);
        g_iWins[client]   = results.FetchInt(1);
        g_iLosses[client] = results.FetchInt(2);
    }
    else
    {
        InsertNewPlayer(client, sSteamID);
        g_iSR[client]    = DEFAULT_SR;
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
        sEscapedID, sEscapedName, DEFAULT_SR, GetTime());
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);
}

void SavePlayerSR(int client)
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
        g_iSR[client], g_iWins[client], g_iLosses[client], GetTime());
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);
}

public void Callback_GenericSQL(Database db, DBResultSet results, const char[] sError, any data)
{
    if (sError[0] != '\0') LogError("[SR] SQL Error: %s", sError);
}

// Lee SR/wins/losses de un SteamID directo de la DB (tabla del modo
// actual). Si el jugador no existe en la tabla, lo crea con DEFAULT_SR.
// Funciona este el jugador conectado o no.
void LeerSRPorSteamID(const char[] sSteamID, int &iSR, int &iWins, int &iLosses)
{
    iSR = DEFAULT_SR; iWins = 0; iLosses = 0;
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
        iSR    = rs.FetchInt(0);
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
        sTable, sEsc, DEFAULT_SR, GetTime());
    SQL_FastQuery(g_DB, sQuery);
}

// Guarda el nombre real del jugador en la DB en cuanto entra al roster.
// Asi, aunque se desconecte antes de terminar la campaña, su nombre
// ya queda guardado y no sale "Desconocido" al actualizar el SR.
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
        sTable, sEscID, sEscNom, DEFAULT_SR, GetTime());
    SQL_FastQuery(g_DB, sQuery);

    Format(sQuery, sizeof(sQuery),
        "UPDATE %s SET nombre = '%s', last_update = %d WHERE steamid = '%s';",
        sTable, sEscNom, GetTime(), sEscID);
    SQL_FastQuery(g_DB, sQuery);
}

// Guarda SR/wins/losses de un SteamID en la DB (tabla del modo actual).
void GuardarSRPorSteamID(const char[] sSteamID, int iSR, int iWins, int iLosses)
{
    if (g_DB == null || sSteamID[0] == '\0') return;

    char sEsc[128];
    SQL_EscapeString(g_DB, sSteamID, sEsc, sizeof(sEsc));

    char sTable[32];
    strcopy(sTable, sizeof(sTable), g_bModoEs1v1 ? "mmr_players_1v1" : "mmr_players");

    char sQuery[512];
    Format(sQuery, sizeof(sQuery),
        "UPDATE %s SET mmr = %d, wins = %d, losses = %d, last_update = %d WHERE steamid = '%s';",
        sTable, iSR, iWins, iLosses, GetTime(), sEsc);
    SQL_FastQuery(g_DB, sQuery);
}

void ObtenerRango(int iSR, char[] sRango, int iMaxRango, char[] sColor, int iMaxColor)
{
    if (iSR >= RANGO_LEYENDA)       { strcopy(sRango, iMaxRango, "Leyenda");   strcopy(sColor, iMaxColor, "\x04"); }
    else if (iSR >= RANGO_MAESTRO)  { strcopy(sRango, iMaxRango, "Maestro");   strcopy(sColor, iMaxColor, "\x04"); }
    else if (iSR >= RANGO_DIAMANTE) { strcopy(sRango, iMaxRango, "Diamante");  strcopy(sColor, iMaxColor, "\x05"); }
    else if (iSR >= RANGO_PLATINO)  { strcopy(sRango, iMaxRango, "Platino");   strcopy(sColor, iMaxColor, "\x05"); }
    else if (iSR >= RANGO_ORO)      { strcopy(sRango, iMaxRango, "Oro");       strcopy(sColor, iMaxColor, "\x04"); }
    else if (iSR >= RANGO_PLATA)    { strcopy(sRango, iMaxRango, "Plata");     strcopy(sColor, iMaxColor, "\x01"); }
    else if (iSR >= RANGO_BRONCE)   { strcopy(sRango, iMaxRango, "Bronce");    strcopy(sColor, iMaxColor, "\x07"); }
    else                              { strcopy(sRango, iMaxRango, "Hierro");    strcopy(sColor, iMaxColor, "\x07"); }
}





// =============================================
// sm_sr_testhud: panel de fin de campaña con los jugadores que estan ahora,
// con cambios de SR inventados. NO guarda nada en la DB.
// =============================================
public Action Cmd_TestHud(int client, int args)
{
    ArmarFinPrueba(IdxSurvivorsSegunJuego(), false);   // en la prueba "ganan" los survivors actuales
    MostrarFinATodos();
    ReplyToCommand(client, "[SR] Panel de prueba mostrado (no se guardo nada).");
    return Plugin_Handled;
}

// Llena el panel de fin con los jugadores actuales y cambios inventados. NO guarda nada.
void ArmarFinPrueba(int iGanador, bool bRendicion)
{
    int iSurvIdx = IdxSurvivorsSegunJuego();
    g_iFinCnt[0] = 0;
    g_iFinCnt[1] = 0;
    g_iFinGanador = iGanador;
    g_bFin1v1 = false;
    g_bFinAbandono = false;
    g_bFinRendicion = bRendicion;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i)) continue;
        int e = EquipoCampania(i, iSurvIdx);
        if (e < 0) continue;
        int f = g_iFinCnt[e]++;
        int iDiff = (e == g_iFinGanador) ? GetRandomInt(20, 45) : -GetRandomInt(20, 45);
        g_iFinCli[e][f]  = i;
        g_iFinDiff[e][f] = iDiff;
        g_iFinSR[e][f]  = g_iSR[i] + iDiff;
        GetClientName(i, g_sFinNom[e][f], MAX_NAME_LENGTH);
    }
}

bool IsValidHuman(int client)
{
    return (client >= 1 && client <= MaxClients
         && IsClientConnected(client)
         && IsClientInGame(client)
         && !IsFakeClient(client));
}

public Action Cmd_SR(int client, int args)
{
    if (client == 0) { PrintToServer("[SR] Solo para jugadores."); return Plugin_Handled; }
    if (!g_bLoaded[client])
    {
        PanelAviso(client, "ClubCampestre :: Mi SR", "Cargando datos, espera un momento...");
        LoadPlayerSR(client);
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
    SQL_TQuery(g_DB, Callback_ShowSR, sQuery, dp);
    return Plugin_Handled;
}

public void Callback_ShowSR(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int client = GetClientOfUserId(dp.ReadCell());
    delete dp;
    if (client == 0 || !IsClientInGame(client)) return;

    if (results != null && sError[0] == '\0' && results.FetchRow())
        g_iRank[client] = results.FetchInt(0);

    ArmarPanelSR(client);
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
            PrintToServer("[SR] #%d %s — %d SR (W:%d/L:%d)", i + 1, g_sTopNom[i], g_iTopSR[i], g_iTopW[i], g_iTopL[i]);
        return;
    }

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client)) return;
    ArmarPanelTop(client);
    HudMostrar(client, g_cvHudSegCmd.IntValue);
}

public Action Cmd_SRJugador(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "[SR] Uso: sm_sr_jugador <nombre>"); return Plugin_Handled; }
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
                PrintToServer("[SR] %s -> SR: %d (W:%d/L:%d)", sName, g_iSR[i], g_iWins[i], g_iLosses[i]);
            else
                PanelJugador(client, "ClubCampestre :: Jugador", sName, g_iSR[i], g_iWins[i], g_iLosses[i]);
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
    SQL_TQuery(g_DB, Callback_SRJugador, sQuery, dp);
    return Plugin_Handled;
}

public void Callback_SRJugador(Database db, DBResultSet results, const char[] sError, DataPack dp)
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
        int iSR = results.FetchInt(1), iW = results.FetchInt(2), iL = results.FetchInt(3);
        if (client == 0) PrintToServer("[SR] %s -> SR: %d (W:%d/L:%d)", sName, iSR, iW, iL);
        else PanelJugador(client, "ClubCampestre :: Jugador", sName, iSR, iW, iL);
    }
    else
    {
        if (client == 0) PrintToServer("[SR] Jugador no encontrado.");
        else PanelAviso(client, "ClubCampestre :: Jugador", "Jugador no encontrado.");
    }
}

public Action Cmd_SetSR(int client, int args)
{
    if (args < 2) { ReplyToCommand(client, "[SR] Uso: sm_setsr <target> <cantidad>"); return Plugin_Handled; }
    char sTarget[64], sAmount[16];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    GetCmdArg(2, sAmount, sizeof(sAmount));
    int target = FindClientByName(sTarget);
    if (target == -1) { ReplyToCommand(client, "[SR] Jugador '%s' no encontrado.", sTarget); return Plugin_Handled; }
    int iOld = g_iSR[target];
    g_iSR[target] = StringToInt(sAmount);
    SavePlayerSR(target);
    char sName[MAX_NAME_LENGTH];
    GetClientName(target, sName, sizeof(sName));
    ReplyToCommand(client, "[SR] SR de %s: %d → %d", sName, iOld, g_iSR[target]);
    char sAviso[96];
    Format(sAviso, sizeof(sAviso), "Un admin ajusto tu SR: %d -> %d", iOld, g_iSR[target]);
    PanelAviso(target, "ClubCampestre :: SR", sAviso);
    return Plugin_Handled;
}

public Action Cmd_ResetSR(int client, int args)
{
    if (args < 1) { ReplyToCommand(client, "[SR] Uso: sm_resetsr <target>"); return Plugin_Handled; }
    char sTarget[64];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    int target = FindClientByName(sTarget);
    if (target == -1) { ReplyToCommand(client, "[SR] Jugador '%s' no encontrado.", sTarget); return Plugin_Handled; }
    g_iSR[target]    = DEFAULT_SR;
    g_iWins[target]   = 0;
    g_iLosses[target] = 0;
    SavePlayerSR(target);
    char sName[MAX_NAME_LENGTH];
    GetClientName(target, sName, sizeof(sName));
    ReplyToCommand(client, "[SR] SR de %s reseteado a %d.", sName, DEFAULT_SR);
    char sAviso[96];
    Format(sAviso, sizeof(sAviso), "Un admin reseteo tu SR a %d", DEFAULT_SR);
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
public Action Cmd_SR1v1(int client, int args)
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
    SQL_TQuery(g_DB, Callback_ShowSR1v1, sQuery, dp);

    return Plugin_Handled;
}

public void Callback_ShowSR1v1(Database db, DBResultSet results, const char[] sError, DataPack dp)
{
    dp.Reset();
    int userid = dp.ReadCell();
    delete dp;

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client)) return;
    if (results == null || sError[0] != '\0') return;

    int iSR = DEFAULT_SR, iW = 0, iL = 0;
    if (results.FetchRow())
    {
        iSR = results.FetchInt(0);
        iW   = results.FetchInt(1);
        iL   = results.FetchInt(2);
    }

    char sNombre[MAX_NAME_LENGTH];
    GetClientName(client, sNombre, sizeof(sNombre));
    PanelJugador(client, "ClubCampestre :: Mi SR 1v1", sNombre, iSR, iW, iL);
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
        int iSR = results.FetchInt(1);
        int iW   = results.FetchInt(2);
        int iL   = results.FetchInt(3);
        results.FetchString(4, sSteam, sizeof(sSteam));

        if (client == 0)
        {
            PrintToServer("%d. %s - %d SR (%dW/%dL)", rank, sName, iSR, iW, iL);
        }
        else
        {
            LineaTop(sLinea, sizeof(sLinea), rank, iSR, iW, iL, sName);
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

public Action Cmd_SetSR1v1(int client, int args)
{
    if (args < 2)
    {
        ReplyToCommand(client, "[SR 1v1] Uso: sm_setsr1v1 <target> <cantidad>");
        return Plugin_Handled;
    }

    char sTarget[64], sAmount[16];
    GetCmdArg(1, sTarget, sizeof(sTarget));
    GetCmdArg(2, sAmount, sizeof(sAmount));

    int iTarget = FindTarget(client, sTarget, true, false);
    if (iTarget == -1) return Plugin_Handled;

    int iNewSR = StringToInt(sAmount);
    if (iNewSR < 0) iNewSR = 0;

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
        sEscID, sEscName, iNewSR, GetTime(), iNewSR, GetTime());
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);

    ReplyToCommand(client, "[SR 1v1] SR 1v1 de %N ajustado a %d.", iTarget, iNewSR);
    return Plugin_Handled;
}

public Action Cmd_ResetSR1v1(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[SR 1v1] Uso: sm_resetsr1v1 <target>");
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
        DEFAULT_SR, GetTime(), sEscID);
    SQL_TQuery(g_DB, Callback_GenericSQL, sQuery);

    ReplyToCommand(client, "[SR 1v1] SR 1v1 de %N reseteado a %d.", iTarget, DEFAULT_SR);
    return Plugin_Handled;
}

void ObtenerRangoWebColors(int iSR, char[] sRango, int rLen,
                           char[] sC1, int c1Len, char[] sC2, int c2Len)
{
    if      (iSR >= 2000) { strcopy(sRango,rLen,"leyenda");  strcopy(sC1,c1Len,"#ff7038"); strcopy(sC2,c2Len,"#cf4010"); }
    else if (iSR >= 1500) { strcopy(sRango,rLen,"maestro");  strcopy(sC1,c1Len,"#a45dff"); strcopy(sC2,c2Len,"#742dcc"); }
    else if (iSR >= 1200) { strcopy(sRango,rLen,"diamante"); strcopy(sC1,c1Len,"#3fb0ff"); strcopy(sC2,c2Len,"#1f80cf"); }
    else if (iSR >= 1000) { strcopy(sRango,rLen,"platino");  strcopy(sC1,c1Len,"#2ee0cc"); strcopy(sC2,c2Len,"#1eb0a0"); }
    else if (iSR >=  800) { strcopy(sRango,rLen,"oro");      strcopy(sC1,c1Len,"#ffcf40"); strcopy(sC2,c2Len,"#d09f20"); }
    else if (iSR >=  650) { strcopy(sRango,rLen,"plata");    strcopy(sC1,c1Len,"#c8d4e2"); strcopy(sC2,c2Len,"#98a4b2"); }
    else if (iSR >=  500) { strcopy(sRango,rLen,"bronce");   strcopy(sC1,c1Len,"#e0954a"); strcopy(sC2,c2Len,"#b07030"); }
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

    int iPos = 0, iLiderSR = -1;
    char sRow[768], sTmp[256];

    while (rs.FetchRow())
    {
        iPos++;
        char sNombre[64]; rs.FetchString(0, sNombre, sizeof(sNombre));
        int  iSR = rs.FetchInt(1);
        int  iW   = rs.FetchInt(2);
        int  iL   = rs.FetchInt(3);
        if (iLiderSR < 0) iLiderSR = iSR;

        char sRango[16], sC1[16], sC2[16];
        ObtenerRangoWebColors(iSR, sRango, sizeof(sRango), sC1, sizeof(sC1), sC2, sizeof(sC2));

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
            "<div class=\"gapn\">%d</div><div class=\"gapl\">SR</div>", iSR - iLiderSR);

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
        Format(sTmp, sizeof(sTmp), "<div class=\"num\">%d</div></div></td>", iSR);
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
        else if (StrEqual(sModo,"rn4v4")) strcopy(sModoUp,sizeof(sModoUp),"4V4 \xC2\xB7 RENDICION");
        else if (StrEqual(sModo,"rn1v1")) strcopy(sModoUp,sizeof(sModoUp),"1V1 \xC2\xB7 RENDICION");
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
    char sInfo[PLATFORM_MAX_PATH + 64];
    if (GenerarWeb(sInfo, sizeof(sInfo))) LogMessage("[SR] Web: %s", sInfo);
    else                                  LogError("[SR] Web: %s", sInfo);
    GenerarMotd();
    return Plugin_Stop;
}

public Action Cmd_WebGenerar(int client, int args)
{
    if (g_DB == null)
    {
        ReplyToCommand(client, "[SR] Web: la DB no esta conectada.");
        return Plugin_Handled;
    }
    char sInfo[PLATFORM_MAX_PATH + 64];
    bool bOk = GenerarWeb(sInfo, sizeof(sInfo));
    ReplyToCommand(client, "[SR] Web: %s", sInfo);
    if (bOk) ReplyToCommand(client, "[SR] Web: el watcher lo sube a GitHub en unos segundos.");

    int iMotd = GenerarMotd();
    if (iMotd > 0) ReplyToCommand(client, "[SR] MOTD: motd.txt generado (%d bytes). Se ve desde el proximo mapa.", iMotd);
    return Plugin_Handled;
}

// -------------------------------------------------------------------------
// Pagina web = la plantilla data/sr_template.html con los datos puestos.
//   Marcadores que entiende (pon solo los que use tu plantilla):
//     {TOP10}               filas del Top 10 (estilo pared)
//     {LAST_UPDATE}         fecha y hora (Lima)
//     {RANKING_ROWS}        ranking completo (plantilla vieja)
//     {PARTIDAS_RECIENTES}  ultimas partidas (plantilla vieja)
//   Con carpeta data/sr_web/: una pagina por plantilla en data/sr_web_out/ (watcher.py sube todo).
//   Sin ella: data/sr_template.html -> data/sr_index.html.
// -------------------------------------------------------------------------
bool GenerarWeb(char[] sInfo, int iInfoLen)
{
    // Varias paginas: cada plantilla de data/sr_web/ sale con su mismo nombre
    // en data/sr_web_out/ (index.html, torneo_eliminatoria.html, ...).
    char sDirIn[PLATFORM_MAX_PATH], sDirOut[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sDirIn,  sizeof(sDirIn),  "data/sr_web");
    BuildPath(Path_SM, sDirOut, sizeof(sDirOut), "data/sr_web_out");

    if (DirExists(sDirIn))
    {
        if (!DirExists(sDirOut)) CreateDirectory(sDirOut, 511);

        DirectoryListing dl = OpenDirectory(sDirIn);
        if (dl == null)
        {
            Format(sInfo, iInfoLen, "no se pudo abrir %s", sDirIn);
            return false;
        }
        char sNombre[PLATFORM_MAX_PATH], sIn[PLATFORM_MAX_PATH], sOut[PLATFORM_MAX_PATH], sErr[PLATFORM_MAX_PATH + 64];
        FileType tipo;
        int iOk = 0, iMal = 0;
        while (dl.GetNext(sNombre, sizeof(sNombre), tipo))
        {
            if (tipo != FileType_File) continue;
            int iLen = strlen(sNombre);
            if (iLen < 6 || StrContains(sNombre[iLen - 5], ".html", false) != 0) continue;
            Format(sIn,  sizeof(sIn),  "%s/%s", sDirIn,  sNombre);
            Format(sOut, sizeof(sOut), "%s/%s", sDirOut, sNombre);
            if (GenerarPagina(sIn, sOut, sErr, sizeof(sErr))) iOk++;
            else { iMal++; LogError("[SR] Web: %s", sErr); }
        }
        delete dl;
        Format(sInfo, iInfoLen, "%d pagina(s) generada(s) en %s%s", iOk, sDirOut, iMal > 0 ? " (hubo errores, mira el log)" : "");
        return iOk > 0;
    }

    // Sin carpeta sr_web: una sola pagina (data/sr_template.html -> data/sr_index.html)
    char sTemplatePath[PLATFORM_MAX_PATH], sIndexPath[PLATFORM_MAX_PATH];
    RutaTemplate(sTemplatePath, sizeof(sTemplatePath));
    BuildPath(Path_SM, sIndexPath, sizeof(sIndexPath), "data/sr_index.html");
    if (!GenerarPagina(sTemplatePath, sIndexPath, sInfo, iInfoLen)) return false;
    Format(sInfo, iInfoLen, "pagina generada -> %s", sIndexPath);
    return true;
}

// Una plantilla -> una pagina con los datos puestos
bool GenerarPagina(const char[] sIn, const char[] sOut, char[] sInfo, int iInfoLen)
{
    File fTmpl = OpenFile(sIn, "r");
    if (fTmpl == null)
    {
        Format(sInfo, iInfoLen, "falta la plantilla %s", sIn);
        return false;
    }
    g_sWebHtml[0] = '\0';
    char sLine[1024];
    while (fTmpl.ReadLine(sLine, sizeof(sLine)))
        StrCat(g_sWebHtml, sizeof(g_sWebHtml), sLine);
    delete fTmpl;

    char sTimestamp[32];
    FormatTime(sTimestamp, sizeof(sTimestamp), "%d/%m/%Y %H:%M");   // hora de la PC
    ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{LAST_UPDATE}", sTimestamp);

    if (StrContains(g_sWebHtml, "{TOP10}") != -1)
    {
        GenerarTop10Muro(g_sWebRanking, sizeof(g_sWebRanking));
        ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{TOP10}", g_sWebRanking);
    }
    if (StrContains(g_sWebHtml, "{RANKING_ROWS}") != -1)
    {
        GenerarRankingRowsWeb(g_sWebRanking, sizeof(g_sWebRanking));
        ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{RANKING_ROWS}", g_sWebRanking);
    }
    if (StrContains(g_sWebHtml, "{PARTIDAS_RECIENTES}") != -1)
    {
        GenerarPartidasWeb(g_sWebPartidas, sizeof(g_sWebPartidas));
        ReplaceString(g_sWebHtml, sizeof(g_sWebHtml), "{PARTIDAS_RECIENTES}", g_sWebPartidas);
    }

    File fOut = OpenFile(sOut, "w");
    if (fOut == null)
    {
        Format(sInfo, iInfoLen, "no se pudo escribir %s", sOut);
        return false;
    }
    fOut.WriteString(g_sWebHtml, false);
    delete fOut;

    Format(sInfo, iInfoLen, "%s (%d bytes)", sOut, strlen(g_sWebHtml));
    return true;
}

// Filas del Top 10 para la pagina de la pared
void GenerarTop10Muro(char[] sOut, int iMaxLen)
{
    sOut[0] = '\0';
    DBResultSet rs = SQL_Query(g_DB,
        "SELECT nombre, mmr, wins, losses FROM mmr_players \
         WHERE steamid NOT LIKE 'STEAM_SIM%' AND (wins+losses)>0 \
         ORDER BY mmr DESC LIMIT 10");
    int iPos = 0;
    if (rs != null)
    {
        char sNom[MAX_NAME_LENGTH], sCorto[MAX_NAME_LENGTH], sEsc[MAX_NAME_LENGTH * 6], sRow[512];
        while (rs.FetchRow())
        {
            iPos++;
            rs.FetchString(0, sNom, sizeof(sNom));
            int iSR = rs.FetchInt(1), iW = rs.FetchInt(2), iL = rs.FetchInt(3);
            RecortarNombre(sNom, sCorto, sizeof(sCorto), 20);
            EscaparHtml(sCorto, sEsc, sizeof(sEsc));
            Format(sRow, sizeof(sRow),
                "<div class=\"fila%s\"><span class=\"fp\">%d.</span><span class=\"fn\">%s</span><span class=\"fs\">%d<small>SR</small></span><span class=\"fw\"><b>%dW</b> &middot; <i>%dL</i></span></div>",
                iPos == 1 ? " r1" : (iPos == 2 ? " r2" : (iPos == 3 ? " r3" : "")), iPos, sEsc, iSR, iW, iL);
            StrCat(sOut, iMaxLen, sRow);
        }
        delete rs;
    }
    if (iPos == 0)
        strcopy(sOut, iMaxLen, "<div class=\"vacio\">Todavia no hay ranking... juega una campa\xC3\xB1a completa.</div>");
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
void LineaResultado(char[] sOut, int iLen, int iDiff, int iSR, const char[] sNombre)
{
    char sDiff[16], sSR[16], sD[48], sM[48], sNom[MAX_NAME_LENGTH];
    Format(sDiff, sizeof(sDiff), "%s%d", iDiff >= 0 ? "+" : "", iDiff);
    IntToString(iSR, sSR, sizeof(sSR));
    Rellenar(sD, sizeof(sD), sDiff, 4);
    Rellenar(sM, sizeof(sM), sSR, 5);
    RecortarNombre(sNombre, sNom, sizeof(sNom), HUD_NOMBRE_MAX);
    Format(sOut, iLen, "%s   %s   %s", sD, sM, sNom);
}

// "#1    3800   13W/7L   Nombre"
void LineaTop(char[] sOut, int iLen, int iPos, int iSR, int iW, int iL, const char[] sNombre)
{
    char sPos[8], sSR[16], sWL[24], sP[32], sM[48], sR[48], sNom[MAX_NAME_LENGTH];
    Format(sPos, sizeof(sPos), "#%d", iPos);
    IntToString(iSR, sSR, sizeof(sSR));
    Format(sWL, sizeof(sWL), "%dW/%dL", iW, iL);
    Rellenar(sP, sizeof(sP), sPos, 3);
    Rellenar(sM, sizeof(sM), sSR, 5);
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

void PanelJugador(int client, const char[] sTitulo, const char[] sNombre, int iSR, int iW, int iL)
{
    char sRango[32], sColor[8], sLinea[HUD_LARGO_LINEA], sNom[MAX_NAME_LENGTH];
    ObtenerRango(iSR, sRango, sizeof(sRango), sColor, sizeof(sColor));
    int iPartidas = iW + iL;
    float fWR = (iPartidas > 0) ? float(iW) / float(iPartidas) * 100.0 : 0.0;

    HudCabecera(client, sTitulo);
    RecortarNombre(sNombre, sNom, sizeof(sNom), HUD_NOMBRE_MAX);
    HudNaranja(client, sNom);
    Format(sLinea, sizeof(sLinea), "Rango:      %s", sRango);      HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "SR:         %d", iSR);        HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Partidas:   %d", iPartidas);   HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Victorias:  %d", iW);          HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Derrotas:   %d", iL);          HudTexto(client, sLinea);
    Format(sLinea, sizeof(sLinea), "Winrate:    %.1f%%", fWR);     HudTexto(client, sLinea);
    HudMostrar(client, g_cvHudSegCmd.IntValue);
}

// !sr (lo usa el comando y la rotacion)
void ArmarPanelSR(int client)
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
    ObtenerRango(g_iSR[client], sRango, sizeof(sRango), sColor, sizeof(sColor));
    int iPartidas = g_iWins[client] + g_iLosses[client];
    float fWR = (iPartidas > 0) ? float(g_iWins[client]) / float(iPartidas) * 100.0 : 0.0;

    Format(sLinea, sizeof(sLinea), "Rango:      %s", sRango);
    HudTexto(client, sLinea);
    if (g_iRank[client] > 0) Format(sLinea, sizeof(sLinea), "SR:         %d   (#%d)", g_iSR[client], g_iRank[client]);
    else                     Format(sLinea, sizeof(sLinea), "SR:         %d", g_iSR[client]);
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
        g_iTopSR[n] = results.FetchInt(1);
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
        LineaTop(sLinea, sizeof(sLinea), i + 1, g_iTopSR[i], g_iTopW[i], g_iTopL[i], g_sTopNom[i]);
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
        if (paso == 0) HudNaranja(client, g_bFinAbandono ? "VICTORIA POR ABANDONO" : (g_bFinRendicion ? "VICTORIA POR RENDICION" : "VICTORIA"));
        else if (g_bFinRendicion) HudNaranja(client, "SE RINDIERON");
        else                      HudNaranja(client, "DERROTA");

        for (int k = 0; k < g_iFinCnt[e]; k++)
        {
            LineaResultado(sLinea, sizeof(sLinea), g_iFinDiff[e][k], g_iFinSR[e][k], g_sFinNom[e][k]);
            if (g_iFinCli[e][k] == client) HudNaranja(client, sLinea);   // tu linea
            else                           HudTexto(client, sLinea);
        }
    }
}

void MostrarFinATodos(int iSegundos = 0)
{
    if (g_iFinGanador < 0 || g_iFinGanador > 1) return;
    PararRotacion();
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (g_iLadoOcultarPanel > 0 && GetClientTeam(i) == g_iLadoOcultarPanel) continue;   // lo vera despues
        ArmarPanelFin(i);
        HudMostrar(i, iSegundos > 0 ? iSegundos : g_cvHudSegFin.IntValue);
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
        else                   ArmarPanelSR(i);
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

// Template de la web: data/sr_template.html (si no existe, usa el nombre viejo mmr_template.html)
void RutaTemplate(char[] sRuta, int iLen)
{
    BuildPath(Path_SM, sRuta, iLen, "data/sr_template.html");
    if (FileExists(sRuta)) return;
    char sViejo[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sViejo, sizeof(sViejo), "data/mmr_template.html");
    if (FileExists(sViejo)) strcopy(sRuta, iLen, sViejo);
}

// ─── Rendicion (lo llama cl4d2_pausa cuando se aprueba !rendirse) ───

// ¿Puede rendirse el equipo del lado iLado (2 = survivors, 3 = infectados)?
//   Devuelve 0 = si | 1 = no (primer capitulo) | 3 = no (la campaña ya termino)
//   iDiferencia (por referencia) = puntos que va perdiendo ese equipo (negativo si va ganando)
public int Native_PuedeRendirse(Handle plugin, int numParams)
{
    int iLado = GetNativeCell(1);
    int iDif = DeficitDelLado(iLado);
    SetNativeCellRef(2, iDif);
    return MotivoNoRendirse(iLado);
}

int DeficitDelLado(int iLado)
{
    if (iLado != TEAM_SURVIVORS && iLado != TEAM_INFECTED) return 0;
    int iScores[2];
    L4D2_GetVersusCampaignScores(iScores);
    int iSurvIdx = IdxSurvivorsSegunJuego();
    int e = (iLado == TEAM_SURVIVORS) ? iSurvIdx : 1 - iSurvIdx;
    return iScores[1 - e] - iScores[e];
}

int MotivoNoRendirse(int iLado)
{
    if (!g_cvEnabled.BoolValue || g_bCampaniaCerrada) return 3;       // campaña ya cerrada
    if (iLado != TEAM_SURVIVORS && iLado != TEAM_INFECTED) return 1;
    if (L4D_IsFirstMapInScenario() || g_iMitadesTotales < 2) return 1;  // primer capitulo: no se puede
    return 0;
}

// El equipo que esta en el lado iLado (2 = survivors, 3 = infectados) se rinde
public int Native_Rendirse(Handle plugin, int numParams)
{
    int iLado = GetNativeCell(1);
    if (MotivoNoRendirse(iLado) != 0) return 0;

    int iSurvIdx = IdxSurvivorsSegunJuego();
    int eRinde = (iLado == TEAM_SURVIVORS) ? iSurvIdx : 1 - iSurvIdx;

    // Anotar a los que estan jugando ahora (sin sumar mitad) antes de cerrar
    RegistrarPresentes(iSurvIdx, false);

    int iScores[2];
    L4D2_GetVersusCampaignScores(iScores);
    LogMessage("[SR] RENDICION: el equipo %s se rinde. Gana el equipo %s.",
        eRinde == 0 ? "A" : "B", eRinde == 0 ? "B" : "A");
    g_iLadoOcultarPanel = iLado;            // los que se rinden ven su panel despues de elegir campaña
    ProcesarResultado(1 - eRinde, -1, iScores, true);
    g_iLadoOcultarPanel = 0;
    return 1;
}

// Muestra el panel de fin (ya calculado) a un jugador. Lo usa cl4d2_pausa despues del menu de campañas.
public int Native_MostrarPanelFin(Handle plugin, int numParams)
{
    int client = GetNativeCell(1);
    if (client < 1 || client > MaxClients || !IsClientInGame(client) || IsFakeClient(client)) return 0;
    if (g_iFinGanador < 0 || g_iFinGanador > 1) return 0;
    ArmarPanelFin(client);
    HudMostrar(client, g_cvHudSegFin.IntValue);
    return 1;
}

// PRUEBA (sm_test_rendirse en cl4d2_pausa): muestra el panel de rendicion con los
// jugadores actuales y numeros inventados. NO guarda nada ni cierra la campaña.
public int Native_PanelRendicionPrueba(Handle plugin, int numParams)
{
    int iLado = GetNativeCell(1);
    int iSurvIdx = IdxSurvivorsSegunJuego();
    int eRinde = (iLado == TEAM_SURVIVORS) ? iSurvIdx : 1 - iSurvIdx;
    ArmarFinPrueba(1 - eRinde, true);
    g_iLadoOcultarPanel = iLado;
    MostrarFinATodos();
    g_iLadoOcultarPanel = 0;
    LogMessage("[SR] PRUEBA de rendicion: panel mostrado (no se guardo nada).");
    return 1;
}

// ─── ¿Ya no puede remontar? (ultimo capitulo) ───
// El equipo del lado iLado va perdiendo y, aunque haga el maximo de puntos en lo que le queda
// de este ultimo capitulo, no alcanza al otro. Lo usa cl4d2_pausa para abrir "¿Se rinden?".
//   Maximo por mitad = puntos maximos del mapa (distancia) + bonus de supervivencia
//                      (vs_survival_bonus x 4) + bonus de desempate (vs_tiebreak_bonus).
//   Se calcula por lo alto, para no pedir rendirse si todavia hay una minima posibilidad.
public int Native_RemontadaImposible(Handle plugin, int numParams)
{
    int iLado = GetNativeCell(1);
    if (MotivoNoRendirse(iLado) != 0) return 0;
    if (!L4D_IsMissionFinalMap()) return 0;
    if (g_iMitadesTerminadas >= 2) return 0;

    int iDeficit = DeficitDelLado(iLado);
    if (iDeficit <= 0) return 0;                       // no va perdiendo

    int iSurvIdx = IdxSurvivorsSegunJuego();
    int e = (iLado == TEAM_SURVIVORS) ? iSurvIdx : 1 - iSurvIdx;

    // ¿Le queda jugar su mitad de survivor en este mapa?
    bool bLeQueda;
    if (g_iMitadesTerminadas == 0) bLeQueda = true;                         // nadie jugo aun
    else                           bLeQueda = (g_iSurvIdxMitad1 != e);      // en la mitad 1 jugo el otro

    int iPotencial = 0;
    if (bLeQueda)
    {
        iPotencial = L4D_GetVersusMaxCompletionScore();
        ConVar cvBonus = FindConVar("vs_survival_bonus");
        ConVar cvTie   = FindConVar("vs_tiebreak_bonus");
        if (cvBonus != null) iPotencial += cvBonus.IntValue * 4;
        if (cvTie   != null) iPotencial += cvTie.IntValue;
    }

    bool bImposible = (iDeficit > iPotencial);
    if (bImposible)
        LogMessage("[SR] Remontada imposible para el equipo %s: pierde por %d y puede sumar como maximo %d.",
            e == 0 ? "A" : "B", iDeficit, iPotencial);
    return bImposible ? 1 : 0;
}

// =========================================================================
// MOTD (motd.txt) con los comandos + Top 10
//   El MOTD de L4D2 solo muestra HTML si va DENTRO del motd.txt (no como link),
//   usa un navegador antiguo y tiene limite de tamaño: por eso es una version
//   liviana (~5 KB). Se arma con data/sr_motd_template.html reemplazando {TOP10}.
//   El juego lee el motd.txt al cargar el mapa: los cambios se ven en el siguiente.
// =========================================================================
public Action Timer_GenerarMotd(Handle timer)
{
    GenerarMotd();
    return Plugin_Stop;
}

void EscaparHtml(const char[] sIn, char[] sOut, int iLen)
{
    strcopy(sOut, iLen, sIn);
    ReplaceString(sOut, iLen, "&", "&amp;");
    ReplaceString(sOut, iLen, "<", "&lt;");
    ReplaceString(sOut, iLen, ">", "&gt;");
    ReplaceString(sOut, iLen, "\"", "&quot;");
}

// Devuelve el tamaño escrito, o 0 si no se genero
int GenerarMotd()
{
    int iModo = g_cvMotd.IntValue;
    if (iModo == 0) return 0;
    if (iModo == 1) return GenerarMotdRedireccion();
    if (g_DB == null) return 0;

    char sTpl[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sTpl, sizeof(sTpl), "data/sr_motd_template.html");
    File f = OpenFile(sTpl, "r");
    if (f == null) return 0;

    static char sHtml[12288];
    sHtml[0] = '\0';
    char sLine[1024];
    while (f.ReadLine(sLine, sizeof(sLine)))
        StrCat(sHtml, sizeof(sHtml), sLine);
    delete f;

    // Top 10
    static char sRows[4096];
    sRows[0] = '\0';
    DBResultSet rs = SQL_Query(g_DB,
        "SELECT nombre, mmr, wins, losses FROM mmr_players \
         WHERE steamid NOT LIKE 'STEAM_SIM%' AND (wins+losses)>0 \
         ORDER BY mmr DESC LIMIT 10");
    int iPos = 0;
    if (rs != null)
    {
        char sNom[MAX_NAME_LENGTH], sCorto[MAX_NAME_LENGTH], sEsc[MAX_NAME_LENGTH * 6];
        char sRango[16], sC1[16], sC2[16], sPos[40], sRow[384];
        while (rs.FetchRow())
        {
            iPos++;
            rs.FetchString(0, sNom, sizeof(sNom));
            int iSR = rs.FetchInt(1), iW = rs.FetchInt(2), iL = rs.FetchInt(3);
            RecortarNombre(sNom, sCorto, sizeof(sCorto), 18);
            EscaparHtml(sCorto, sEsc, sizeof(sEsc));
            ObtenerRangoWebColors(iSR, sRango, sizeof(sRango), sC1, sizeof(sC1), sC2, sizeof(sC2));
            if (StrEqual(sRango, "hierro")) strcopy(sC1, sizeof(sC1), "#a7b0b8");   // gris legible sobre la pared

            if      (iPos == 1) strcopy(sPos, sizeof(sPos), " style=\"color:#ffd23a\"");
            else if (iPos == 2) strcopy(sPos, sizeof(sPos), " style=\"color:#e9e9e9\"");
            else if (iPos == 3) strcopy(sPos, sizeof(sPos), " style=\"color:#e0954a\"");
            else                sPos[0] = '\0';

            Format(sRow, sizeof(sRow),
                "<tr><td class=\"p\"%s>%d.</td><td class=\"n\">%s</td><td class=\"v\" style=\"color:%s\">%d</td><td class=\"k\">%dW %dL</td></tr>",
                sPos, iPos, sEsc, sC1, iSR, iW, iL);
            StrCat(sRows, sizeof(sRows), sRow);
        }
        delete rs;
    }
    if (iPos == 0)
        strcopy(sRows, sizeof(sRows), "<tr><td>Todavia no hay ranking... juega una campaña completa.</td></tr>");

    ReplaceString(sHtml, sizeof(sHtml), "{TOP10}", sRows);

    File fo = OpenFile("motd.txt", "w");   // left4dead2/motd.txt
    if (fo == null)
    {
        LogError("[SR] MOTD: no se pudo escribir motd.txt");
        return 0;
    }
    fo.WriteString(sHtml, false);
    delete fo;

    int iLen = strlen(sHtml);
    LogMessage("[SR] MOTD: motd.txt generado (%d bytes, top %d).", iLen, iPos);
    return iLen;
}

// -------------------------------------------------------------------------
// Modo 1: motd.txt chiquito (HTML) que salta a la pagina publicada.
//   El juego solo acepta link si el archivo EMPIEZA con "http"; si empieza con
//   "<" lo abre como pagina HTML local, y desde ahi el navegador del MOTD puede
//   ir a cualquier pagina (asi lo hacen los servers que muestran imagenes).
//   Tiene que empezar exactamente con '<' (sin espacios ni BOM).
// -------------------------------------------------------------------------
int GenerarMotdRedireccion()
{
    char sUrl[512];
    g_cvMotdUrl.GetString(sUrl, sizeof(sUrl));
    TrimString(sUrl);
    if (sUrl[0] == '\0') return 0;
    ReplaceString(sUrl, sizeof(sUrl), "\"", "%22");

    // ?t= cambia en cada mapa para que no use una copia vieja (Top 10 al dia)
    char sSep[2];
    strcopy(sSep, sizeof(sSep), (StrContains(sUrl, "?") == -1) ? "?" : "&");

    static char sHtml[2048];
    Format(sHtml, sizeof(sHtml),
        "<html><head><meta charset=\"UTF-8\"><meta http-equiv=\"refresh\" content=\"0;url=%s%st=%d\">\
<style>body{background:#3c3a35;color:#d8d1bd;font-family:Impact,sans-serif;font-size:22px;margin:0;padding:30px}</style></head>\
<body>cargando...<script>location.replace(\"%s%st=%d\");</script></body></html>",
        sUrl, sSep, GetTime(), sUrl, sSep, GetTime());

    File fo = OpenFile("motd.txt", "w");
    if (fo == null)
    {
        LogError("[SR] MOTD: no se pudo escribir motd.txt");
        return 0;
    }
    fo.WriteString(sHtml, false);
    delete fo;

    int iLen = strlen(sHtml);
    LogMessage("[SR] MOTD: motd.txt -> %s (%d bytes).", sUrl, iLen);
    return iLen;
}
