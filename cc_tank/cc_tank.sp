#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <left4dhooks>

#define TEAM_SURVIVOR   2
#define TEAM_INFECTED   3
#define ZC_TANK         8

// Etiqueta de los mensajes. Cambiala aca si quieres otra (ej: "\x04[Tank]\x01" o "\x04[\xE2\x98\x850]\x01").
#define TAG "\x04[Tank]\x01"

// Sonido del contador (un tick por segundo). Cambialo aca si quieres otro.
#define TICK_SOUND "buttons/blip1.wav"

// Sonido que suena para todos cuando aparece un tank (solo al spawnear, no al pasarlo).
#define TANK_SPAWN_SOUND "ui/pickup_secret01.wav"

ConVar g_cvEnabled;
ConVar g_cvBossFlowMin;   // versus_boss_flow_min (cvar del juego, el mismo que usa ZoneMod)
ConVar g_cvBossFlowMax;   // versus_boss_flow_max
ConVar g_cvMenu;
ConVar g_cvMenuTime;
ConVar g_cvAviso;          // quien ve el aviso de a quien le toca el tank
ConVar g_cvMapInfo;
ConVar g_cvRelleno;
ConVar g_cvRocas;

// Selector de rocas (como "l4d2_tank_attack_control" de ZoneMod)
// Secuencias de lanzamiento: 49 = 1 mano por encima, 50 = lateral, 51 = 2 manos por encima
int  g_iRocaElegida[MAXPLAYERS + 1];   // 1, 2 o 3 (se suma 48 para la secuencia)
bool g_bRocaPorComando[MAXPLAYERS + 1];

char   g_sFlowMap[64];         // mapa al que pertenece g_fChapterFlow
bool   g_bTankYaSalio;         // ya aparecio un tank en esta ronda (para !tankflow)

int    g_iRellenos;            // veces que se relleno la barra de este tank
bool   g_bForzadoEsteMapa;     // el plugin forzo el tank en este mapa (para desbloquearlo si el mapa lo prohibe)

// Datos del mapa actual (leidos de cc_tank_mapinfo o de los datos de ZoneMod incluidos)
#define MAX_BANS 16
float g_fBanMin[MAX_BANS];     // zonas prohibidas para el tank, en % de flow (0-100)
float g_fBanMax[MAX_BANS];
int   g_iBanCount;
bool  g_bZFix;                 // corregir tank que spawnea muy abajo/arriba de los survivors
float g_fMaxTankZ;
float g_vWarpTo[3];

bool   g_bTankAlive;           // hay un tank vivo (una "vida" de tank en curso). No se resetea al cambiar de dueño
int    g_iBotHeredero;         // userid del bot que heredo el tank de un humano frustrado

ArrayList g_hWhosHadTank;      // SteamIDs que ya fueron tank en esta campaña
char      g_sQueuedTank[64];   // SteamID del que sera tank este capitulo
char      g_sLastTank[64];     // SteamID del ultimo que jugo tank (para no repetir seguido)
bool      g_bCampaignResetDone;

Handle g_hMenuTimer;           // timer del contador
Menu   g_hActiveMenu;          // menu de tank abierto actualmente (para no cortar el contador al reabrirlo)
int    g_iMenuTimeLeft;        // segundos restantes
int    g_iMenuTankUserId;      // userid del tank al que le sale el contador

float  g_fChapterFlow;         // punto (flow) del tank para el capitulo actual

Handle g_hPollTimer;           // timer que vigila quien controla el tank
int    g_iMenuPollTries;       // intentos del sondeo directo (para el respaldo a los 2s)
bool   g_bMenuShownThisTank;   // ya se mostro el menu para este tank
bool   g_bTankMarked;          // ya se corrigio el registro para este tank
bool   g_bTankChosenThisRound; // ya se eligio tank este capitulo (evita re-sortear por cada survivor)
bool   g_bTankAnnouncedThisRound; // ya se aviso a los admins este capitulo (solo una vez, pase lo que pase)
bool   g_bSpawnSoundPlayed;    // ya sono el sonido de aparicion para este tank (evita duplicados)
float  g_fMenuShownTime;       // GetEngineTime() cuando se mostro el menu (para grace period)

public Plugin myinfo =
{
    name        = "CC Tank Control",
    author      = "Kydium",
    description = "Reparte el tank equitativamente, lo fuerza en cada capitulo (menos finales) en zonas seguras y lo pasa al bot al frustrarse. Solo depende de left4dhooks.",
    version     = "2.3.0",
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnabled  = CreateConVar("cc_tank_enabled",   "1",  "Activar el plugin.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMenu     = CreateConVar("cc_tank_menu",      "1",  "Mostrarle al que recibe el tank un menu para quedarselo o pasarlo.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMenuTime = CreateConVar("cc_tank_menu_time", "15", "Segundos que dura el menu para elegir.", FCVAR_NOTIFY, true, 5.0, true, 120.0);
    g_cvAviso    = CreateConVar("cc_tank_aviso",     "0",  "Quien ve el aviso de a quien le toca el tank cada capitulo: 0 = solo admins, 1 = todos los jugadores.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRelleno  = CreateConVar("cc_tank_relleno",   "1",  "Veces que se le rellena la barra de frustracion al jugador (como ZoneMod) antes de que el tank pase al bot. 0 = va directo al bot.", FCVAR_NOTIFY, true, 0.0, true, 5.0);
    g_cvRocas    = CreateConVar("cc_tank_rocas",     "1",  "Selector de rocas del tank: R = 2 manos, E = lateral, clic derecho = 1 mano (como ZoneMod).", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvMapInfo  = CreateConVar("cc_tank_mapinfo",   "cfg/cc_tank/mapinfo.txt", "Archivo con las zonas prohibidas del tank por mapa. Si no existe, se crea con los datos de ZoneMod incluidos.", FCVAR_NOTIFY);

    // Rango donde puede salir el tank: los cvars del juego, igual que ZoneMod
    // (ZoneMod los pone en 0.20 y 0.85).
    g_cvBossFlowMin = FindConVar("versus_boss_flow_min");
    g_cvBossFlowMax = FindConVar("versus_boss_flow_max");

    RegConsoleCmd("sm_overhand",    Cmd_RocaDosManos, "Tank: lanzar roca con 2 manos por encima de la cabeza.");
    RegConsoleCmd("sm_underhand",   Cmd_RocaLateral,  "Tank: lanzar roca lateral.");
    RegConsoleCmd("sm_overonehand", Cmd_RocaUnaMano,  "Tank: lanzar roca con 1 mano por encima de la cabeza.");

    RegAdminCmd("sm_tankflow", Cmd_TankFlow, ADMFLAG_GENERIC, "Muestra el progreso actual (como el !current de ZoneMod) y en que % sale el tank.");

    AutoExecConfig(true, "cc_tank");

    g_hWhosHadTank = new ArrayList(ByteCountToCells(64));

    // Comandos de admin (sustituciones)
    RegAdminCmd("sm_tankshuffle", Cmd_TankShuffle, ADMFLAG_SLAY,    "Sortea de nuevo al azar quien sera el tank.");
    RegAdminCmd("sm_givetank",    Cmd_GiveTank,    ADMFLAG_SLAY,    "Le da el tank a un jugador especifico.");

    // Consulta (solo admins)
    RegAdminCmd("sm_tank", Cmd_WhoTank, ADMFLAG_GENERIC, "Muestra quien sera el tank (solo admins).");
    RegAdminCmd("sm_boss", Cmd_WhoTank, ADMFLAG_GENERIC, "Muestra quien sera el tank (solo admins).");

    HookEvent("round_start",            Event_RoundStart,    EventHookMode_PostNoCopy);
    HookEvent("round_end",              Event_RoundEnd,      EventHookMode_PostNoCopy);
    HookEvent("player_left_start_area", Event_LeftStartArea, EventHookMode_PostNoCopy);
    HookEvent("player_team",            Event_PlayerTeam,    EventHookMode_Post);
    HookEvent("player_death",           Event_PlayerDeath,   EventHookMode_Post);
    HookEvent("tank_spawn",             Event_TankSpawn,     EventHookMode_Post);
    HookEvent("player_hurt",            Event_PlayerHurt,    EventHookMode_Post);
}

/*=========================================================================
| Deteccion de nueva campaña (para reiniciar el pool de quien-ya-fue-tank)|
=========================================================================*/
public void OnMapStart()
{
    PrecacheSound(TICK_SOUND);
    PrecacheSound(TANK_SPAWN_SOUND);

    // El primer mapa de la campaña se carga 2 veces (una por cada mitad/equipo).
    // El flag evita reiniciar el pool en la segunda mitad del mapa 1.
    if (L4D_IsFirstMapInScenario())
    {
        if (!g_bCampaignResetDone)
        {
            g_hWhosHadTank.Clear();
            g_sQueuedTank = "";
            g_sLastTank   = "";
            g_bCampaignResetDone = true;
        }
    }
    else
    {
        g_bCampaignResetDone = false;
    }

    CargarDatosMapa();
}

// Datos por defecto (zonas prohibidas del tank y correccion de altura), sacados del
// mapinfo.txt de ZoneMod. Se escriben a cc_tank_mapinfo si el archivo no existe.
char g_sMapInfoDefault[][] =
{
    "\"MapInfo\"",
    "{",
    "\t\"c1m1_hotel\"",
    "\t{",
    "\t\t\"tank_z_fix\"\t\"1\"",
    "\t\t\"max_tank_z\"\t\"1200.000000\"",
    "\t\t\"tank_warpto\"\t\"2168.357666 5803.427734 2464.031250\"",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Instant spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"25\"",
    "\t\t\t}",
    "\t\t\t\"Before elevator top, after elevator bottom\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"33\"",
    "\t\t\t\t\"max\"\t\"79\"",
    "\t\t\t}",
    "\t\t\t\"After kitchen\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"85\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c1m2_streets\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"One way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"49\"",
    "\t\t\t\t\"max\"\t\"55\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c1m3_mall\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Event escalators\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"64\"",
    "\t\t\t\t\"max\"\t\"68\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c2m2_fairgrounds\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Alley choke to up top\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"56\"",
    "\t\t\t\t\"max\"\t\"68\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c2m3_coaster\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"One way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"38\"",
    "\t\t\t\t\"max\"\t\"41\"",
    "\t\t\t}",
    "\t\t\t\"Coaster Start\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"56\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c3m1_plankcountry\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Before ferry (bugged spawn)\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"45\"",
    "\t\t\t\t\"max\"\t\"62\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c3m2_swamp\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Late tanks\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"75\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c4m1_milltown_a\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"20\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c4m2_sugarmill_a\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Field\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"77\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c4m3_sugarmill_b\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Elevator\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"23\"",
    "\t\t\t\t\"max\"\t\"36\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c5m1_waterfront\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"38\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c5m2_park\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"CEDA trailer\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"49\"",
    "\t\t\t\t\"max\"\t\"54\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c5m3_cemetery\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Sewer and parking lot\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"54\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c5m4_quarter\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Last one way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"80\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c6m1_riverbank\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Late Alley\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"58\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c6m2_bedlam\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Sewer Drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"58\"",
    "\t\t\t\t\"max\"\t\"68\"",
    "\t\t\t}",
    "\t\t\t\"Event (bugged spawn)\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"73\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c7m2_barge\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Event (bugged spawn)\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"70\"",
    "\t\t\t\t\"max\"\t\"78\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c8m1_apartment\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"One way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"31\"",
    "\t\t\t\t\"max\"\t\"43\"",
    "\t\t\t}",
    "\t\t\t\"Alley\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"59\"",
    "\t\t\t\t\"max\"\t\"67\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c8m3_sewers\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Late warehouse and before one way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"50\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t\t\"During event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"29\"",
    "\t\t\t\t\"max\"\t\"35\"",
    "\t\t\t}",
    "\t\t\t\"Early spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"22\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c8m4_interior\"",
    "\t{",
    "\t\t\"tank_z_fix\"\t\"1\"",
    "\t\t\"max_tank_z\"\t\"4000.000000\"",
    "\t\t\"tank_warpto\"\t\"13439 15017 450\"",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Before elevator (bugged spawn)\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"42\"",
    "\t\t\t\t\"max\"\t\"81\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c8m5_rooftop\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"45\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c10m1_caves\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Ladders\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"38\"",
    "\t\t\t\t\"max\"\t\"42\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c10m2_drainage\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Tunnel spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"40\"",
    "\t\t\t\t\"max\"\t\"51\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c10m4_mainstreet\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Start of event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"65\"",
    "\t\t\t\t\"max\"\t\"75\"",
    "\t\t\t}",
    "\t\t\t\"End of event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"83\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c12m1_hilltop\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"50\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c12m3_bridge\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Saferoom tank\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"28\"",
    "\t\t\t}",
    "\t\t\t\"Late spawns (bugged spawn)\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"81\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c12m5_cornfield\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"After one way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"80\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c13m1_alpinecreek\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"After one way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"87\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c13m2_southpinestream\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"82\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c13m3_memorialbridge\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Event and bridge descent\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"52\"",
    "\t\t\t\t\"max\"\t\"64\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c14m2_lighthouse\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"30\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c5m1_darkwaterfront\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"38\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c5m3_darkcemetery\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Sewers and parking lot\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"50\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"c5m4_darkquarter\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"After one way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"80\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"cdta_01detour\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Valley one way drop until house\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"34\"",
    "\t\t\t\t\"max\"\t\"63\"",
    "\t\t\t}",
    "\t\t\t\"may spawn in water\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"70\"",
    "\t\t\t\t\"max\"\t\"72\"",
    "\t\t\t}",
    "\t\t\t\"Late spawns\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"78\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"cdta_02road\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"61\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"cdta_03warehouse\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"During sewers + double ladder drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"52\"",
    "\t\t\t\t\"max\"\t\"79\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"cdta_05finalroad\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_deathaboard03_docks\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"25\"",
    "\t\t\t\t\"max\"\t\"50\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_deathaboard04_ship\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"40\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_ihm03_underground\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"70\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_ihm04_lumberyard\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"25\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"cwm2_warehouse\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"72\"",
    "\t\t\t\t\"max\"\t\"99\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_stadium1_apartment\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"45\"",
    "\t\t\t}",
    "\t\t\t\"Block point of no return tank\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"75\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_stadium3_city1\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"40\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_stadium4_city2\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"75\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_city17_02\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"80\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_city17_03\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"55\"",
    "\t\t\t\t\"max\"\t\"68\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_city17_04\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"25\"",
    "\t\t\t\t\"max\"\t\"68\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_dbd2dc_anna_is_gone\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early Tank awkward spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"44\"",
    "\t\t\t}",
    "\t\t\t\"Alarm car to one way drop\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"50\"",
    "\t\t\t\t\"max\"\t\"75\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_dbd2dc_clean_up\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early Tank awkward spawn all the way up to vent spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"24\"",
    "\t\t\t\t\"max\"\t\"45\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_dbd2dc_undead_center\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"down the platform\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"57\"",
    "\t\t\t\t\"max\"\t\"63\"",
    "\t\t\t}",
    "\t\t\t\"through the vent\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"73\"",
    "\t\t\t\t\"max\"\t\"75\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_dbd2dc_new_dawn\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"uf2_rooftops\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"60\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_149_1\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"30\"",
    "\t\t\t\t\"max\"\t\"62\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_149_3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"75\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_149_4\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"45\"",
    "\t\t\t\t\"max\"\t\"85\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"eu02_castle_b16\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"55\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"srocchurch\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"25\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"jsarena201_town\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"75\"",
    "\t\t\t\t\"max\"\t\"99\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"jsarena202_alley\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"35\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"jsarena203_roof\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"72\"",
    "\t\t\t\t\"max\"\t\"99\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"jsarena204_arena\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"86\"",
    "\t\t\t\t\"max\"\t\"99\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"versus_1\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"84\"",
    "\t\t\t\t\"max\"\t\"99\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"versus_3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"30\"",
    "\t\t\t\t\"max\"\t\"78\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"versus_4\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"1\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_bts01_forest\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"1\"",
    "\t\t\t\t\"max\"\t\"50\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_bts02_station\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"1\"",
    "\t\t\t\t\"max\"\t\"40\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"RiverMotel\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"20\"",
    "\t\t\t\t\"max\"\t\"55\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"CityHall\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"35\"",
    "\t\t\t\t\"max\"\t\"72\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_diescraper1_apartment_361\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"30\"",
    "\t\t\t\t\"max\"\t\"50\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"damitdc1\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"30\"",
    "\t\t\t\t\"max\"\t\"50\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"damitdc2\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"75\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"damitdc3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"45\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"damitdc4\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_tbm_2\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"52\"",
    "\t\t\t\t\"max\"\t\"88\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_tbm_3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"60\"",
    "\t\t\t\t\"max\"\t\"80\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_tbm_4\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"25\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d_tbm_5\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"50\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_fallindeath04\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"40\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_daybreak04_cruise\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"35\"",
    "\t\t\t\t\"max\"\t\"60\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_ff03_highway\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Elevator\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"55\"",
    "\t\t\t\t\"max\"\t\"75\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"l4d2_ff04_plant\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Alarm event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"56\"",
    "\t\t\t\t\"max\"\t\"99\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"nmrm1_apartment\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"56\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"nmrm2_subway\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"26\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"nmrm3_sewers\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"31\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"nmrm4_hospital\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"20\"",
    "\t\t\t}",
    "\t\t\t\"Elevator\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"36\"",
    "\t\t\t\t\"max\"\t\"72\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"nmrm5_rooftop\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Early spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"46\"",
    "\t\t\t}",
    "\t\t\t\"Late spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"76\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"noecho_m1\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"alarmcar\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"40\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"noecho_m2\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"riverside\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"35\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"noecho_m3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"parking area\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"43\"",
    "\t\t\t}",
    "\t\t\t\"alarmcar\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"47\"",
    "\t\t\t\t\"max\"\t\"51\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"noecho_m4\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"container route\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"71\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"noecho_m5\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"alarmcar\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"42\"",
    "\t\t\t\t\"max\"\t\"50\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"pr3_highway_f\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Unfair spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"27\"",
    "\t\t\t\t\"max\"\t\"37\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"pr4_quarter_f\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Unfair spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"55\"",
    "\t\t\t\t\"max\"\t\"63\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"tripday_new_m2\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"early\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"28\"",
    "\t\t\t}",
    "\t\t\t\"cornfield\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"36\"",
    "\t\t\t\t\"max\"\t\"66\"",
    "\t\t\t}",
    "\t\t\t\"down the ladder\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"71\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"tripday_new_m3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"near_building\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"74\"",
    "\t\t\t\t\"max\"\t\"99\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"tripday_new_m4\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"early\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"32\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"tripday_new_m5\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"near_gas_station\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"52\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"x1m2_path\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Outside the cave\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"82\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"x1m4_forest\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"70\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"dcr_m1_hotel\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"1\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"21\"",
    "\t\t\t}",
    "\t\t\t\"2\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"37\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"dcr_m3_mall\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"52\"",
    "\t\t\t\t\"max\"\t\"68\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"dc2025_1\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Roof to saferoom\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"38\"",
    "\t\t\t\t\"max\"\t\"70\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"dc2025_2\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Parking\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"72\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"dc2025_3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"Event spawn\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"72\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"snowtown_m1\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"early\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"0\"",
    "\t\t\t\t\"max\"\t\"35\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"snowtown_m3\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"lane\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"76\"",
    "\t\t\t\t\"max\"\t\"81\"",
    "\t\t\t}",
    "\t\t\t\"late\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"84\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"snowtown_m4\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"stairs\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"25\"",
    "\t\t\t\t\"max\"\t\"30\"",
    "\t\t\t}",
    "\t\t\t\"late\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"67\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "\t\"snowtown_m5\"",
    "\t{",
    "\t\t\"tank_ban_flow\"",
    "\t\t{",
    "\t\t\t\"near the event\"",
    "\t\t\t{",
    "\t\t\t\t\"min\"\t\"67\"",
    "\t\t\t\t\"max\"\t\"100\"",
    "\t\t\t}",
    "\t\t}",
    "\t}",
    "}"
};

// Mapas que ya traen su propio tank (lista "static_tank_map" de ZoneMod, mas c13m2 que
// ZoneMod excluye en bossspawningfix). En estos el plugin no fuerza ningun tank extra
// ni toca la configuracion de jefes: los maneja el propio mapa.
char g_sMapasTankFijo[][] =
{
    "c1m4_atrium",
    "c4m5_milltown_escape",
    "c5m5_bridge",
    "c6m3_port",
    "c7m1_docks",
    "c7m3_port",
    "c13m2_southpinestream",
    "c13m4_cutthroatcreek",
    "l4d2_darkblood04_extraction",
    "x1m5_salvation",
    "uf4_airfield",
    "dprm5_milltown_escape",
    "l4d2_diescraper4_top_361",
    "dkr_m1_motel",
    "dkr_m2_carnival",
    "dkr_m3_tunneloflove",
    "dkr_m4_ferris",
    "dkr_m5_stadium",
    "cdta_05finalroad",
    "l4d_dbd2dc_new_dawn",
    "dcr_m4_atrium",
    "dc2025_4",
    "dc2025_5"
};

bool EsMapaTankFijo()
{
    char map[64];
    GetCurrentMap(map, sizeof(map));
    for (int i = 0; i < sizeof(g_sMapasTankFijo); i++)
    {
        if (StrEqual(map, g_sMapasTankFijo[i], false))
            return true;
    }
    return false;
}

// Crea las carpetas de la ruta (ej: cfg/cc_tank/) y escribe el archivo por defecto.
void CrearMapInfoDefault(const char[] path)
{
    char dir[PLATFORM_MAX_PATH];
    int len = strlen(path);
    for (int i = 0; i < len; i++)
    {
        if (path[i] == '/' || path[i] == '\\')
        {
            strcopy(dir, i + 1, path);
            if (!DirExists(dir))
                CreateDirectory(dir, 511);
        }
    }

    File f = OpenFile(path, "w");
    if (f == null)
    {
        LogError("[cc_tank] No se pudo crear %s", path);
        return;
    }
    for (int i = 0; i < sizeof(g_sMapInfoDefault); i++)
        f.WriteLine("%s", g_sMapInfoDefault[i]);
    delete f;

    LogMessage("[cc_tank] Creado %s (%d lineas, datos de ZoneMod).", path, sizeof(g_sMapInfoDefault));
}

/*=========================================================================
| Datos por mapa: zonas prohibidas del tank y correccion de altura
| (mismo formato que el mapinfo.txt de ZoneMod)
=========================================================================*/
void CargarDatosMapa()
{
    g_bForzadoEsteMapa = false;
    g_iBanCount = 0;
    g_bZFix     = false;
    g_fMaxTankZ = 0.0;
    g_vWarpTo[0] = 0.0; g_vWarpTo[1] = 0.0; g_vWarpTo[2] = 0.0;

    char map[64];
    GetCurrentMap(map, sizeof(map));

    char path[PLATFORM_MAX_PATH];
    g_cvMapInfo.GetString(path, sizeof(path));

    // Primera vez: se crea la carpeta y el archivo con los datos de ZoneMod incluidos.
    // Si ya existe no se toca, asi puedes editarlo a mano.
    if (path[0] != '\0' && !FileExists(path))
        CrearMapInfoDefault(path);

    KeyValues kv = new KeyValues("MapInfo");
    bool ok = (path[0] != '\0' && FileExists(path) && kv.ImportFromFile(path));
    if (!ok)
        ok = ImportarDatosIncluidos(kv);   // sin archivo (o ilegible): los datos de ZoneMod incluidos

    if (ok && kv.JumpToKey(map))
    {
        g_bZFix     = kv.GetNum("tank_z_fix", 0) == 1;
        g_fMaxTankZ = kv.GetFloat("max_tank_z", 0.0);
        kv.GetVector("tank_warpto", g_vWarpTo);

        if (kv.JumpToKey("tank_ban_flow") && kv.GotoFirstSubKey())
        {
            do
            {
                if (g_iBanCount >= MAX_BANS)
                    break;
                g_fBanMin[g_iBanCount] = kv.GetFloat("min", 0.0);
                g_fBanMax[g_iBanCount] = kv.GetFloat("max", 0.0);
                g_iBanCount++;
            }
            while (kv.GotoNextKey());
        }
    }
    delete kv;
}

// Carga en kv los datos de ZoneMod que trae el plugin
bool ImportarDatosIncluidos(KeyValues kv)
{
    int size = 1;
    for (int i = 0; i < sizeof(g_sMapInfoDefault); i++)
        size += strlen(g_sMapInfoDefault[i]) + 1;

    char[] buf = new char[size];
    int pos = 0;
    for (int i = 0; i < sizeof(g_sMapInfoDefault); i++)
    {
        pos += strcopy(buf[pos], size - pos, g_sMapInfoDefault[i]);
        buf[pos++] = '\n';
    }
    buf[pos] = '\0';
    return kv.ImportFromString(buf, "cc_tank_mapinfo");
}

/*=========================================================================
| Armas T1 en c1m1_hotel (mismas posiciones que el Stripper de ZoneMod)
=========================================================================*/
Action Timer_ArmasC1M1(Handle timer)
{
    char map[64];
    GetCurrentMap(map, sizeof(map));
    if (!StrEqual(map, "c1m1_hotel", false))
        return Plugin_Stop;

    float pos[3], ang[3];

    // Saferoom
    pos[0] = 429.0;  pos[1] = 5573.0; pos[2] = 2850.0;  ang[0] = 0.0; ang[1] = 254.0; ang[2] = 84.0;
    PonerArma("weapon_smg_silenced", pos, ang, 650);
    pos[0] = 430.0;  pos[1] = 5531.0; pos[2] = 2850.0;  ang[0] = 0.0; ang[1] = 254.0; ang[2] = 84.0;
    PonerArma("weapon_shotgun_chrome", pos, ang, 96);

    // Primer pasillo
    pos[0] = 1771.0; pos[1] = 5781.0; pos[2] = 2657.0;  ang[0] = 0.0; ang[1] = 316.0; ang[2] = -90.0;
    PonerArma("weapon_smg", pos, ang, 650);
    pos[0] = 1775.0; pos[1] = 5742.0; pos[2] = 2657.0;  ang[0] = 0.0; ang[1] = 276.5; ang[2] = -90.0;
    PonerArma("weapon_pumpshotgun", pos, ang, 72);
    return Plugin_Stop;
}

// Pone un arma suelta (se recoge una vez). Si ya hay un arma ahi (ej: la puso el
// Stripper de ZoneMod), no la duplica.
void PonerArma(const char[] clase, const float pos[3], const float ang[3], int ammo)
{
    char cls[64];
    float ePos[3];
    int maxEnt = GetMaxEntities();
    for (int e = MaxClients + 1; e < maxEnt; e++)
    {
        if (!IsValidEntity(e) || !GetEntityClassname(e, cls, sizeof(cls)))
            continue;
        if (StrContains(cls, "weapon_") != 0)
            continue;
        GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", ePos);
        if (GetVectorDistance(pos, ePos) < 10.0)
            return;
    }

    int ent = CreateEntityByName(clase);
    if (ent == -1)
        return;

    char sAmmo[16];
    IntToString(ammo, sAmmo, sizeof(sAmmo));
    DispatchKeyValue(ent, "ammo", sAmmo);
    DispatchKeyValue(ent, "spawnflags", "1");
    DispatchKeyValueVector(ent, "origin", pos);
    DispatchKeyValueVector(ent, "angles", ang);

    if (!DispatchSpawn(ent))
    {
        RemoveEntity(ent);
        return;
    }
    TeleportEntity(ent, pos, ang, NULL_VECTOR);
}

// Elige un porcentaje ENTERO al azar dentro de [fMin, fMax] (0-1), evitando las zonas
// prohibidas (incluidos sus bordes, como ZoneMod). Devuelve el flow exacto (ej: 0.31)
// o -1.0 si no queda ningun porcentaje permitido.
float ElegirFlowPermitido(float fMin, float fMax)
{
    int desde = RoundToCeil(fMin * 100.0);
    int hasta = RoundToFloor(fMax * 100.0);

    ArrayList validos = new ArrayList();
    for (int p = desde; p <= hasta; p++)
    {
        bool prohibido = false;
        for (int b = 0; b < g_iBanCount; b++)
        {
            if (float(p) >= g_fBanMin[b] && float(p) <= g_fBanMax[b])
            {
                prohibido = true;
                break;
            }
        }
        if (!prohibido)
            validos.Push(p);
    }

    float flow = -1.0;
    if (validos.Length > 0)
        flow = float(validos.Get(GetRandomInt(0, validos.Length - 1))) / 100.0;
    delete validos;
    return flow;
}

// Si el tank aparece muy por debajo/encima de algun survivor (ej: abajo del ascensor
// en c1m1 antes de que lo llamen), lo lleva al punto seguro del mapa. Igual que confogl.
void CorregirAlturaTank(int tank)
{
    if (!g_bZFix || g_fMaxTankZ <= 0.0 || GetVectorLength(g_vWarpTo, true) == 0.0)
        return;

    float tPos[3], sPos[3];
    GetClientAbsOrigin(tank, tPos);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVOR || !IsPlayerAlive(i))
            continue;
        GetClientAbsOrigin(i, sPos);
        if (FloatAbs(sPos[2] - tPos[2]) > g_fMaxTankZ)
        {
            TeleportEntity(tank, g_vWarpTo, NULL_VECTOR, NULL_VECTOR);
            return;
        }
    }
}

/*=========================================================================
| Eventos |
=========================================================================*/
void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    // Armas T1 en c1m1 (el mapa solo trae pistola y melee). Un poco despues del
    // round_start, cuando el mapa ya termino de crear sus entidades.
    CreateTimer(1.0, Timer_ArmasC1M1, _, TIMER_FLAG_NO_MAPCHANGE);

    CreateTimer(0.5, Timer_ForzarTank, _, TIMER_FLAG_NO_MAPCHANGE);
    g_bTankYaSalio = false;

    g_sQueuedTank        = "";
    g_bMenuShownThisTank = false;
    g_bTankMarked        = false;
    g_bTankChosenThisRound = false;
    g_bTankAnnouncedThisRound = false;
    g_bSpawnSoundPlayed = false;
    ResetTankLife();
    StopTankCountdown();
}

void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_sQueuedTank = "";
    ClearTankTimers();
}

// Mata los timers pendientes (sondeo y contador) para no dejar basura entre rondas.
void ClearTankTimers()
{
    if (g_hPollTimer != null)
    {
        KillTimer(g_hPollTimer);
        g_hPollTimer = null;
    }
    ResetTankLife();
    StopTankCountdown();
}

// Termina la "vida" del tank: todo vuelve a vanilla para el proximo.
void ResetTankLife()
{
    g_bTankAlive      = false;
    g_iBotHeredero    = 0;
    g_iRellenos       = 0;
}

// Los survivors salen del saferoom: se elige al tank (una sola vez por capitulo,
// aunque el evento dispare por cada survivor).
void Event_LeftStartArea(Event event, const char[] name, bool dontBroadcast)
{
    EnsureTankChosen();
}

// El punto del tank se fija al empezar la ronda, igual que ZoneMod: si se fija despues
// de salir del saferoom, el juego ya calculo donde sacarlo y lo ignora.
Action Timer_ForzarTank(Handle timer)
{
    if (DebeForzar())
        ForceTankSpawn();
    return Plugin_Stop;
}

// Mapas donde el plugin fuerza el tank: no finales, no mapas con tank propio, y el
// primer capitulo solo si cc_tank_primer_mapa esta activo.
bool DebeForzar()
{
    if (!g_cvEnabled.BoolValue)
        return false;
    if (L4D_IsMissionFinalMap() || EsMapaTankFijo())
        return false;
    return true;
}

// Unico punto de entrada para la PRIMERA eleccion de tank del capitulo. Se puede
// llamar desde Event_LeftStartArea Y desde el fallback en L4D_OnTryOfferingTankBot
// (por si uno dispara antes que el otro); el guard evita que ambos elijan por separado.
void EnsureTankChosen()
{
    if (g_bTankChosenThisRound)
        return;
    g_bTankChosenThisRound = true;

    if (g_cvEnabled.BoolValue)
        ChooseTank();
}

// Si el elegido se cambia de equipo o se desconecta, elegimos a otro.
void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    int oldTeam = event.GetInt("oldteam");
    int client  = GetClientOfUserId(event.GetInt("userid"));

    if (client < 1 || client > MaxClients || IsFakeClient(client))
        return;
    if (oldTeam != TEAM_INFECTED)
        return;
    if (!g_cvEnabled.BoolValue)
        return;

    char steamId[64];
    if (!GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId)))
        return;

    if (StrEqual(steamId, g_sQueuedTank))
        RequestFrame(Frame_ReChoose);
}

void Frame_ReChoose(any data)
{
    if (!g_cvEnabled.BoolValue)
        return;
    ChooseTank();
}

// Aparece un tank: sonido, anillo, duracion de la barra y menu para el que lo controle.
void Event_TankSpawn(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvEnabled.BoolValue)
        return;

    // Al jugador que recibe el tank (aparicion o cambio de dueño): como lanzar cada roca
    int receptor = GetClientOfUserId(event.GetInt("userid"));
    if (g_cvRocas.BoolValue && receptor > 0 && IsClientInGame(receptor) && !IsFakeClient(receptor))
    {
        PrintToChat(receptor, "%s Selector de roca:", TAG);
        PrintToChat(receptor, "\x05(R) Recargar\x01 = 2 manos por encima de la cabeza");
        PrintToChat(receptor, "\x05(E) Usar\x01 = Lateral");
        PrintToChat(receptor, "\x05Clic derecho\x01 = 1 mano por encima de la cabeza");
    }

    // tank_spawn tambien se dispara cada vez que el tank CAMBIA DE DUEÑO (bot -> jugador,
    // pase por menu, frustracion). Eso no es un tank nuevo: no se resetea nada.
    // La "vida" del tank solo termina cuando ya no queda ningun tank vivo.
    if (g_bTankAlive)
        return;

    g_bTankAlive    = true;
    g_bTankYaSalio  = true;
    g_iBotHeredero  = 0;
    g_iRellenos     = 0;

    // Un solo tank por recorrido en cada ronda (fuera de los finales): si el mapa saco
    // su propio tank antes, ya no sale el del plugin. Si salio el del plugin, el juego
    // ya lo dio por usado.
    if (!L4D_IsMissionFinalMap())
        L4D2Direct_SetVSTankToSpawnThisRound(IsSecondHalf() ? 1 : 0, false);

    // Sonido de aviso para todos (solo al aparecer, no al pasarlo entre jugadores).
    if (!g_bSpawnSoundPlayed)
    {
        g_bSpawnSoundPlayed = true;
        SonarParaTodos(TANK_SPAWN_SOUND);
    }

    // Tank que aparecio muy por debajo/encima de los survivors (ej: c1m1) -> punto seguro
    int tank = GetClientOfUserId(event.GetInt("userid"));
    if (tank > 0 && IsClientInGame(tank) && IsPlayerAlive(tank))
        CorregirAlturaTank(tank);

    g_bMenuShownThisTank = false;
    g_bTankMarked        = false;
    g_iMenuPollTries     = 0;

    if (g_hPollTimer != null)
        KillTimer(g_hPollTimer);
    g_hPollTimer = CreateTimer(0.25, Timer_ShowMenuDirect, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// Intenta detectar el momento EXACTO en que el humano ya controla el tank
// (sondeando cada 0.25s). Si a los 2s todavia no se pudo confirmar, muestra
// el menu igual como respaldo (evita el bug viejo de "nunca aparece").
Action Timer_ShowMenuDirect(Handle timer)
{
    if (g_bMenuShownThisTank)
    {
        g_hPollTimer = null;
        return Plugin_Stop;
    }

    g_iMenuPollTries++;

    int client = GetCurrentTankClient();
    bool confirmed = (client != -1);

    // Respaldo: a los 2s (8 intentos), mostramos igual aunque no se haya podido
    // confirmar por deteccion directa, usando al jugador que quedo en cola.
    if (!confirmed && g_iMenuPollTries < 8)
        return Plugin_Continue;

    if (!confirmed)
        client = GetInfectedBySteamId(g_sQueuedTank);

    g_hPollTimer = null;

    if (client == -1 || IsFakeClient(client))
        return Plugin_Stop;

    MarkActualTank(client);
    OnHumanTookTank(client);
    return Plugin_Stop;
}

// La PRIMERA vez que un humano tiene el tank en esta vida: menu + pase al bot al frustrarse.
void OnHumanTookTank(int client)
{
    g_bMenuShownThisTank = true;
    g_fMenuShownTime     = GetEngineTime();

    if (g_cvMenu.BoolValue)
        ShowTankMenu(client);

    AsegurarPaseABot();
}

// Corrige el registro: el que controla el tank es el que cuenta como "ya le toco".
void MarkActualTank(int tankClient)
{
    char actualId[64];
    if (!GetClientAuthId(tankClient, AuthId_Steam2, actualId, sizeof(actualId)))
        return;

    // Solo la PRIMERA vez: si el tank lo agarro alguien distinto al elegido, el elegido
    // no gasta su turno. En pases posteriores no borramos a nadie, porque los anteriores
    // si llegaron a jugar el tank.
    if (!g_bTankMarked)
    {
        g_bTankMarked = true;
        if (g_sQueuedTank[0] != '\0' && !StrEqual(actualId, g_sQueuedTank))
        {
            int idx = g_hWhosHadTank.FindString(g_sQueuedTank);
            if (idx != -1)
                g_hWhosHadTank.Erase(idx);
        }
    }

    if (g_hWhosHadTank.FindString(actualId) == -1)
        g_hWhosHadTank.PushString(actualId);

    strcopy(g_sLastTank, sizeof(g_sLastTank), actualId);
}

// Cancela el menu si el tank hace daño real a un survivor (no al tirar piedra, solo al golpear).
void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (g_hMenuTimer == null)
        return;

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    if (attacker <= 0 || attacker != GetClientOfUserId(g_iMenuTankUserId))
        return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim <= 0 || GetClientTeam(victim) != TEAM_SURVIVOR)
        return;

    CancelTankWindow();
}

// Cierra el menu/contador: el tank ya se comprometio, se queda.
void CancelTankWindow()
{
    // Grace period: los primeros 3 segundos no cancelamos aunque ataque.
    // El bot puede estar pegando justo cuando el humano toma control, lo que
    // cerraria el menu antes de que el jugador lo vea.
    if (GetEngineTime() - g_fMenuShownTime < 3.0)
        return;

    if (g_hMenuTimer == null && g_iMenuTankUserId == 0)
        return;

    int client = GetClientOfUserId(g_iMenuTankUserId);
    StopTankCountdown();

    if (client > 0 && IsClientInGame(client))
    {
        CancelClientMenu(client);
        PrintToChat(client, "%s Empezaste a atacar, te quedas de \x04Tank\x01.", TAG);
    }
}

// Cuando muere un tank (finales con varios), preparamos al siguiente.
void Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidInfected(victim))
        return;
    if (GetEntProp(victim, Prop_Send, "m_zombieClass") == ZC_TANK && g_cvEnabled.BoolValue)
    {
        // Se revisa un frame despues: si el tank solo cambio de dueño, sigue habiendo uno vivo.
        RequestFrame(Frame_TankDeathCheck);
    }
}

void Frame_TankDeathCheck(any data)
{
    if (CountAliveTanks() > 0)
        return;

    ResetTankLife();
    g_bSpawnSoundPlayed = false; // el proximo tank (finales con varios) tambien debe sonar
    if (g_cvEnabled.BoolValue)
        ChooseTank();
}

// Tanks vivos (humanos o bots)
int CountAliveTanks()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i)
         && GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
            n++;
    }
    return n;
}

/*=========================================================================
| Frustracion: relleno (como ZoneMod) y despues pase al bot
=========================================================================*/
// Mecanismo oficial del juego (documentado en left4dhooks): con el contador de pases
// en mas de 1, cuando la barra se acaba el tank se cambia por un BOT, sin pasar por
// otro jugador. Mientras queden rellenos no se activa, para que el juego vuelva a
// avisar (L4D_OnTryOfferingTankBot) y se pueda rellenar.
void AsegurarPaseABot()
{
    if (g_iRellenos < g_cvRelleno.IntValue)
        return;
    if (L4D2Direct_GetTankPassedCount() < 2)
        L4D2Direct_SetTankPassedCount(2);
}

/*=========================================================================
| Forzar spawn del tank
=========================================================================*/
// Igual que "bossspawningfix" de ZoneMod, solo en mapas donde este plugin fuerza el tank:
// el script del mapa puede prohibir jefes (ProhibitBosses) o vetar el tank (DisallowThreatType).
public Action L4D_OnGetScriptValueInt(const char[] key, int &retVal)
{
    if (!g_bForzadoEsteMapa)
        return Plugin_Continue;

    if (StrEqual(key, "ProhibitBosses") || StrEqual(key, "DisallowThreatType"))
    {
        retVal = 0;
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

// Igual que ZoneMod: que la configuracion de la campaña (mision) no decida por su cuenta
// si sale tank ni donde; manda el punto que fija el plugin. En los mapas con tank
// propio y en los finales no se toca nada.
public Action L4D_OnGetMissionVSBossSpawning(float &spawn_pos_min, float &spawn_pos_max, float &tank_chance, float &witch_chance)
{
    return DebeForzar() ? Plugin_Handled : Plugin_Continue;
}

// sm_tankflow: igual que el !current de ZoneMod. Progreso = posicion ACTUAL del
// superviviente mas adelantado + versus_boss_buffer (el adelanto con que el juego saca
// al tank). Redondeado al mas cercano, igual que el % del tank. El tank sale cuando
// "Actual" llega al numero del tank.
Action Cmd_TankFlow(int client, int args)
{
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlow <= 0.0)
    {
        ReplyToCommand(client, "%s No se pudo leer el recorrido de este mapa.", TAG);
        return Plugin_Handled;
    }

    float flow = -1.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVOR && IsPlayerAlive(i))
        {
            float f = FlowActual(i);
            if (f > flow)
                flow = f;
        }
    }
    if (flow < 0.0)
    {
        ReplyToCommand(client, "%s No hay supervivientes en el recorrido.", TAG);
        return Plugin_Handled;
    }

    ConVar buffer = FindConVar("versus_boss_buffer");
    float actual = (flow + (buffer != null ? buffer.FloatValue : 0.0)) / maxFlow;
    if (actual > 1.0)
        actual = 1.0;
    int iActual = RoundToNearest(actual * 100.0);

    int  r     = IsSecondHalf() ? 1 : 0;
    int  iTank = RoundToNearest(L4D2Direct_GetVSTankFlowPercent(r) * 100.0);
    bool sale  = L4D2Direct_GetVSTankToSpawnThisRound(r);

    // Aunque el tank ya haya salido, se sigue mostrando su porcentaje.
    if (sale || g_bTankYaSalio)
        ReplyToCommand(client, "%s Actual: %d%%. Tank: sale en %d%%.", TAG, iActual, iTank);
    else
        ReplyToCommand(client, "%s Actual: %d%%. Tank: no sale en este mapa.", TAG, iActual);
    return Plugin_Handled;
}

// Flow (distancia en el recorrido) del lugar donde esta el jugador AHORA. -1 si no se sabe.
float FlowActual(int client)
{
    Address area = L4D_GetLastKnownArea(client);
    if (area == Address_Null)
        return -1.0;
    return L4D2Direct_GetTerrorNavAreaFlow(area);
}


void ForceTankSpawn()
{
    char map[64];
    GetCurrentMap(map, sizeof(map));

    // Igual que ZoneMod: en la 2da mitad no se toca nada, ya quedo fijado en la 1ra
    // para las dos rondas (mismo punto para ambos equipos).
    if (IsSecondHalf())
    {
        g_bForzadoEsteMapa = (g_fChapterFlow >= 0.0 && StrEqual(map, g_sFlowMap));
        return;
    }

    float fMin = (g_cvBossFlowMin != null) ? g_cvBossFlowMin.FloatValue : 0.20;
    float fMax = (g_cvBossFlowMax != null) ? g_cvBossFlowMax.FloatValue : 0.85;
    if (fMin > fMax)
    {
        float tmp = fMin; fMin = fMax; fMax = tmp;
    }

    // Punto al azar evitando las zonas prohibidas del mapa (mapinfo de ZoneMod).
    g_fChapterFlow = ElegirFlowPermitido(fMin, fMax);
    strcopy(g_sFlowMap, sizeof(g_sFlowMap), map);
    if (g_fChapterFlow < 0.0)
        return;   // ningun tramo permitido en este mapa: lo decide el juego

    g_bForzadoEsteMapa = true;
    int pct = RoundToNearest(g_fChapterFlow * 100.0);
    LogMessage("[cc_tank] %s: tank forzado en %d%%.", map, pct);

    // Tank en ambas rondas y en NUESTRO punto (una sola vez, como ZoneMod).
    for (int round = 0; round < 2; round++)
    {
        L4D2Direct_SetVSTankToSpawnThisRound(round, true);
        L4D2Direct_SetVSTankFlowPercent(round, g_fChapterFlow);
    }
}

// % del mapa del survivor mas adelantado (0-100)
float FlowSurvivors()
{
    float maxFlow = L4D2Direct_GetMapMaxFlowDistance();
    if (maxFlow <= 0.0)
        return 0.0;
    return L4D2_GetFurthestSurvivorFlow() / maxFlow * 100.0;
}

// Un jugador perdio el tank y otro lo recibio. Si lo recibio un bot (barra acabada),
// se recuerda cual es para que se quede con el.
public void L4D_OnReplaceTank(int tank, int newtank)
{
    if (newtank > 0 && newtank <= MaxClients && IsClientInGame(newtank) && IsFakeClient(newtank))
        g_iBotHeredero = GetClientUserId(newtank);
}

// Diagnostico: el juego intento sacar un tank y otro plugin lo bloqueo
public void L4D_OnSpawnTank_PostHandled(int client, const float vecPos[3], const float vecAng[3])
{
    LogTank("El juego intento sacar el tank pero OTRO PLUGIN lo bloqueo (survivors en %.0f%%).", FlowSurvivors());
}

// El juego va a entregar el tank: a un humano (tank nuevo) o, si ya lo tiene un humano,
// es porque se le acabo la barra.
public Action L4D_OnTryOfferingTankBot(int tank_index, bool &enterStatis)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    // Tank en manos de un HUMANO = se le acabo la barra (igual que en ZoneMod).
    // Plugin_Handled hace que el jugador se QUEDE con el tank (no se le ofrece a nadie).
    if (!IsFakeClient(tank_index))
    {
        if (g_iRellenos < g_cvRelleno.IntValue)
        {
            // Relleno: barra llena otra vez, mismo jugador.
            g_iRellenos++;
            SetEntProp(tank_index, Prop_Send, "m_frustration", 0);
            PrintToChat(tank_index, "%s Se te relleno la barra de frustracion. La proxima vez, el tank pasa al bot.", TAG);
            AsegurarPaseABot();
            return Plugin_Handled;
        }

        // Sin rellenos (no deberia pasar: con el contador de pases en 2 el juego ya lo
        // cambia por bot sin preguntar). Por si acaso, igual que ZoneMod: nunca se retiene
        // al jugador con la barra vacia; se le rellena y la proxima vez va al bot.
        SetEntProp(tank_index, Prop_Send, "m_frustration", 0);
        if (L4D2Direct_GetTankPassedCount() < 2)
            L4D2Direct_SetTankPassedCount(2);
        return Plugin_Handled;
    }

    // El bot que heredo el tank de un humano frustrado se lo queda (Handled = mantener bot).
    // Solo ESE bot: otro tank nuevo (ej: el segundo de un final) se entrega normal.
    if (g_iBotHeredero != 0 && GetClientUserId(tank_index) == g_iBotHeredero)
        return Plugin_Handled;

    // Tank nuevo: se le entrega al elegido (si todavia no se eligio, se elige ahora).
    EnsureTankChosen();
    if (g_sQueuedTank[0] != '\0')
        ApplyTankTickets();

    return Plugin_Continue;
}

/*=========================================================================
| Reparto equitativo |
=========================================================================*/
void ChooseTank()
{
    ArrayList eligible = new ArrayList();
    char steamId[64];

    // Elegibles = infectados humanos que aun no fueron tank
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidInfected(i) || IsFakeClient(i))
            continue;
        if (!GetClientAuthId(i, AuthId_Steam2, steamId, sizeof(steamId)))
            continue;
        if (g_hWhosHadTank.FindString(steamId) == -1)
            eligible.Push(i);
    }

    // Si ya todos los del equipo actual fueron tank, empieza vuelta nueva PARA ELLOS.
    // Ojo: solo se les quita la marca a ellos, no se borra la lista entera, porque el
    // otro equipo (que rota de lado cada capitulo) tiene su propio historial ahi dentro.
    if (eligible.Length == 0)
    {
        for (int i = 1; i <= MaxClients; i++)
        {
            if (!IsValidInfected(i) || IsFakeClient(i))
                continue;
            if (!GetClientAuthId(i, AuthId_Steam2, steamId, sizeof(steamId)))
                continue;

            int idx = g_hWhosHadTank.FindString(steamId);
            if (idx != -1)
                g_hWhosHadTank.Erase(idx);

            eligible.Push(i);
        }
    }

    if (eligible.Length == 0)
    {
        delete eligible;
        g_sQueuedTank = "";
        return;
    }

    // Si hay mas de un candidato, el ultimo tank no repite (evita 2 veces seguidas).
    if (eligible.Length > 1 && g_sLastTank[0] != '\0')
    {
        for (int i = eligible.Length - 1; i >= 0; i--)
        {
            int c = eligible.Get(i);
            if (GetClientAuthId(c, AuthId_Steam2, steamId, sizeof(steamId)) && StrEqual(steamId, g_sLastTank))
            {
                eligible.Erase(i);
                break;
            }
        }
    }

    if (eligible.Length == 0)
    {
        delete eligible;
        g_sQueuedTank = "";
        return;
    }

    int pick = eligible.Get(GetRandomInt(0, eligible.Length - 1));
    delete eligible;

    GetClientAuthId(pick, AuthId_Steam2, g_sQueuedTank, sizeof(g_sQueuedTank));

    // Ojo: no lo marcamos aca. Se marca en MarkActualTank cuando de verdad
    // agarre el tank, asi nadie gasta su turno sin haberlo jugado.
    ApplyTankTickets();

    // El anuncio a admins solo sale UNA VEZ por capitulo, sin importar cuantas
    // veces ChooseTank() se re-ejecute despues (reconexiones, cambios de equipo, etc.)
    if (!g_bTankAnnouncedThisRound)
    {
        g_bTankAnnouncedThisRound = true;
        NotifyAdminsTank(pick);
    }
}

void ApplyTankTickets()
{
    int tankClient = GetInfectedBySteamId(g_sQueuedTank);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidInfected(i) || IsFakeClient(i))
            continue;
        L4D2Direct_SetTankTickets(i, (i == tankClient) ? 20000 : 0);
    }
}

/*=========================================================================
| Comandos |
=========================================================================*/
Action Cmd_WhoTank(int client, int args)
{
    if (g_sQueuedTank[0] == '\0')
    {
        ReplyToCommand(client, "[Tank] Aun no hay tank asignado.");
        return Plugin_Handled;
    }

    int tankClient = GetInfectedBySteamId(g_sQueuedTank);
    if (tankClient == -1)
    {
        ReplyToCommand(client, "[Tank] El tank asignado ya no esta conectado.");
        return Plugin_Handled;
    }

    if (client > 0 && client == tankClient)
        PrintToChat(client, "%s Tu seras el \x04Tank\x01.", TAG);
    else if (client > 0)
        PrintToChat(client, "%s \x05%N\x01 sera el \x04Tank\x01.", TAG, tankClient);
    else
        PrintToServer("[Tank] %N sera el Tank.", tankClient);

    return Plugin_Handled;
}

Action Cmd_TankShuffle(int client, int args)
{
    // Nota: ya no tocamos el registro aca. El elegido solo se marca cuando de verdad
    // controla el tank, asi que resortear no le quita el turno a nadie.
    ChooseTank();
    ReplyToCommand(client, "[Tank] Se resorteo el tank.");
    return Plugin_Handled;
}

Action Cmd_GiveTank(int client, int args)
{
    if (args < 1)
    {
        ReplyToCommand(client, "[Tank] Uso: sm_givetank <jugador>");
        return Plugin_Handled;
    }

    char arg[64];
    GetCmdArg(1, arg, sizeof(arg));

    int target = FindTarget(client, arg, true, false); // nobots=true
    if (target == -1)
        return Plugin_Handled; // FindTarget ya avisa del error

    if (GetClientTeam(target) != TEAM_INFECTED)
    {
        ReplyToCommand(client, "[Tank] %N no esta en el equipo infectado.", target);
        return Plugin_Handled;
    }

    // Solo lo dejamos como elegido. Se marcara cuando de verdad controle el tank.
    GetClientAuthId(target, AuthId_Steam2, g_sQueuedTank, sizeof(g_sQueuedTank));

    ApplyTankTickets();
    ReplyToCommand(client, "[Tank] Le diste el tank a %N.", target);
    return Plugin_Handled;
}

/*=========================================================================
| Notificacion al admin |
=========================================================================*/

// Aviso de a quien le toca el tank este capitulo: solo admins o todos (cc_tank_aviso).
void NotifyAdminsTank(int tankClient)
{
    if (!IsClientInGame(tankClient))
        return;
    bool todos = g_cvAviso.BoolValue;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;
        if (todos || CheckCommandAccess(i, "sm_givetank", ADMFLAG_SLAY, true))
            PrintToChat(i, "%s \x05%N\x01 sera el \x04Tank\x01 este capitulo.", TAG, tankClient);
    }
}

/*=========================================================================
| Utilidades |
=========================================================================*/
bool IsValidInfected(int client)
{
    return client > 0 && client <= MaxClients && IsClientInGame(client) && GetClientTeam(client) == TEAM_INFECTED;
}

// True si el infectado puede recibir el tank: muerto (esperando spawn) o en modo
// fantasma. Si ya esta vivo y materializado como SI, NO puede (evita el bug de
// teletransporte al pasarle el tank mientras tiene agarrado a un survivor).
bool IsAvailableForTank(int client)
{
    if (!IsPlayerAlive(client))
        return true;
    return GetEntProp(client, Prop_Send, "m_isGhost") == 1;
}

// Aviso importante: a los admins por chat y al log de SourceMod (queda guardado
// aunque se cierre el juego: addons/sourcemod/logs/L*.log).
void LogTank(const char[] fmt, any ...)
{
    char msg[256];
    VFormat(msg, sizeof(msg), fmt, 2);
    char map[64];
    GetCurrentMap(map, sizeof(map));
    LogMessage("[cc_tank] %s: %s", map, msg);
    AvisarAdmins("%s", msg);
}

void AvisarAdmins(const char[] fmt, any ...)
{
    char msg[256];
    VFormat(msg, sizeof(msg), fmt, 2);
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && CheckCommandAccess(i, "sm_givetank", ADMFLAG_SLAY, true))
            PrintToChat(i, "%s %s", TAG, msg);
    }
}

// True si estamos en la 2da mitad del capitulo (el otro equipo jugando el mismo mapa).
bool IsSecondHalf()
{
    return GameRules_GetProp("m_bInSecondHalfOfRound") > 0;
}

int GetInfectedBySteamId(const char[] steamId)
{
    if (steamId[0] == '\0')
        return -1;

    char tmp[64];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidInfected(i))
            continue;
        if (!GetClientAuthId(i, AuthId_Steam2, tmp, sizeof(tmp)))
            continue;
        if (StrEqual(tmp, steamId))
            return i;
    }
    return -1;
}

/*=========================================================================
| Menu de control de Tank |
=========================================================================*/
// time = 0 -> usa cc_tank_menu_time completo; >0 -> tiempo restante (al reabrir).
void ShowTankMenu(int tankClient, int time = 0)
{
    if (!g_cvMenu.BoolValue)
        return;

    if (tankClient < 1 || tankClient > MaxClients || !IsClientInGame(tankClient) || IsFakeClient(tankClient))
        return;

    Menu menu = new Menu(TankMenu_Handler);
    menu.SetTitle("Menu de control de Tank");

    menu.AddItem("keep",   "Quiero seguir siendo tank");
    menu.AddItem("anyone", "Cualquiera menos yo");

    // Resto de infectados humanos, para pasarles el tank directo.
    // Los que ya estan vivos como SI no aparecen (evita el bug de teletransporte).
    char steamId[64], display[MAX_NAME_LENGTH + 8];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidInfected(i) || IsFakeClient(i) || i == tankClient)
            continue;
        if (!IsAvailableForTank(i))
            continue;
        GetClientAuthId(i, AuthId_Steam2, steamId, sizeof(steamId));
        Format(display, sizeof(display), "%N", i);
        menu.AddItem(steamId, display);
    }

    menu.ExitButton = true;

    if (time <= 0)
        time = g_cvMenuTime.IntValue;
    g_hActiveMenu = menu;
    menu.Display(tankClient, time);
    StartTankCountdown(tankClient, time);
}

/*=========================================================================
| Contador en pantalla (HUD abajo-centro) + sonido |
=========================================================================*/
void StartTankCountdown(int client, int time)
{
    StopTankCountdown();

    g_iMenuTankUserId = GetClientUserId(client);
    g_iMenuTimeLeft   = time;

    ShowCountdownFrame();
    g_hMenuTimer = CreateTimer(1.0, Timer_TankCountdown, _, TIMER_REPEAT);
}

void StopTankCountdown()
{
    if (g_hMenuTimer != null)
    {
        KillTimer(g_hMenuTimer);
        g_hMenuTimer = null;
    }

    g_iMenuTankUserId = 0;
}

Action Timer_TankCountdown(Handle timer)
{
    g_iMenuTimeLeft--;

    int client = GetClientOfUserId(g_iMenuTankUserId);
    if (client == 0 || !IsClientInGame(client) || g_iMenuTimeLeft <= 0)
    {
        g_hMenuTimer = null;
        g_iMenuTankUserId = 0;
        return Plugin_Stop;
    }

    ShowCountdownFrame();
    return Plugin_Continue;
}

void ShowCountdownFrame()
{
    int client = GetClientOfUserId(g_iMenuTankUserId);
    if (client == 0 || !IsClientInGame(client))
        return;

    // PrintHintText sale abajo al centro y si funciona en L4D2 (a diferencia del HUD normal)
    PrintHintText(client, "%d", g_iMenuTimeLeft);

    ClientCommand(client, "play %s", TICK_SOUND);
}

int TankMenu_Handler(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_End)
    {
        // Solo cortamos el contador si el que se cierra es el menu activo
        // (si se reabrio uno nuevo, el contador es de ese y debe seguir).
        if (menu == g_hActiveMenu)
        {
            StopTankCountdown();
            g_hActiveMenu = null;
        }
        delete menu;
        return 0;
    }

    if (action != MenuAction_Select)
        return 0;

    char info[64];
    menu.GetItem(param2, info, sizeof(info));

    // El que elige debe seguir vivo e infectado.
    if (!IsClientInGame(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_INFECTED)
    {
        PrintToChat(client, "%s Ya no controlas el tank.", TAG);
        return 0;
    }

    if (StrEqual(info, "keep"))
    {
        PrintToChat(client, "%s Te quedas como \x04Tank\x01.", TAG);
    }
    else if (StrEqual(info, "anyone"))
    {
        int newTank = PickReplacement(client);
        if (newTank == -1)
        {
            PrintToChat(client, "%s No hay a quien pasarle el tank.", TAG);
            return 0;
        }
        PassLiveTank(client, newTank);
        PrintToChat(client, "%s Cediste el \x04Tank\x01 a \x05%N\x01.", TAG, newTank);
    }
    else
    {
        int target = GetInfectedBySteamId(info);
        if (target == -1 || target == client)
        {
            PrintToChat(client, "%s Ese jugador ya no esta disponible.", TAG);
            return 0;
        }
        // Pudo haber spawneado mientras el menu estaba abierto.
        if (!IsAvailableForTank(target))
        {
            PrintToChat(client, "%s \x05%N\x01 ya esta vivo como infectado, elige a otro.", TAG, target);
            if (g_iMenuTimeLeft > 0)
                ShowTankMenu(client, g_iMenuTimeLeft);
            return 0;
        }
        PassLiveTank(client, target);
        PrintToChat(client, "%s Le pasaste el \x04Tank\x01 a \x05%N\x01.", TAG, target);
    }

    return 0;
}

// Mueve el control del tank vivo de un jugador a otro y actualiza el reparto
void PassLiveTank(int oldTank, int newTank)
{
    L4D_ReplaceTank(oldTank, newTank);

    // El que lo recibe por el menu tambien pasa al bot al frustrarse.
    AsegurarPaseABot();

    char steamId[64];
    if (GetClientAuthId(newTank, AuthId_Steam2, steamId, sizeof(steamId)))
    {
        strcopy(g_sQueuedTank, sizeof(g_sQueuedTank), steamId);
        if (g_hWhosHadTank.FindString(steamId) == -1)
            g_hWhosHadTank.PushString(steamId);
    }
}

// Elige a un reemplazo al azar: primero entre los que no han sido tank, si no cualquiera
int PickReplacement(int exclude)
{
    ArrayList pref = new ArrayList();
    ArrayList any  = new ArrayList();
    char steamId[64];

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidInfected(i) || IsFakeClient(i) || i == exclude)
            continue;
        if (!IsAvailableForTank(i))
            continue;
        any.Push(i);
        GetClientAuthId(i, AuthId_Steam2, steamId, sizeof(steamId));
        if (g_hWhosHadTank.FindString(steamId) == -1)
            pref.Push(i);
    }

    int result = -1;
    if (pref.Length > 0)
        result = pref.Get(GetRandomInt(0, pref.Length - 1));
    else if (any.Length > 0)
        result = any.Get(GetRandomInt(0, any.Length - 1));

    delete pref;
    delete any;
    return result;
}

// Devuelve el jugador humano que controla el tank vivo, o -1.
int GetCurrentTankClient()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidInfected(i) || IsFakeClient(i))
            continue;
        if (!IsPlayerAlive(i))
            continue;
        if (GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
            return i;
    }
    return -1;
}

// Sonido para todos los jugadores con "play" en su propio juego. Funciona igual en
// servidor dedicado y en servidor creado desde el juego (ahi el host no recibe los
// sonidos por red, y no se le puede reconocer por IP: aparece como "loopback").
void SonarParaTodos(const char[] sound)
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
            ClientCommand(i, "play %s", sound);
    }
}

/*=========================================================================
| Selector de rocas (igual que "l4d2_tank_attack_control" de ZoneMod)
| R = 2 manos por encima, E = lateral, clic derecho = 1 mano por encima.
| Tambien con !overhand, !underhand y !overonehand (para bindear otra tecla).
=========================================================================*/
public void OnClientConnected(int client)
{
    g_bRocaPorComando[client] = false;
    g_iRocaElegida[client]    = 0;
}

bool EsTank(int client)
{
    return GetClientTeam(client) == TEAM_INFECTED && IsPlayerAlive(client)
        && GetEntProp(client, Prop_Send, "m_zombieClass") == ZC_TANK;
}

Action ElegirRocaPorComando(int client, int tipo)
{
    if (!g_cvRocas.BoolValue || client < 1 || !IsClientInGame(client) || !EsTank(client))
        return Plugin_Continue;
    g_bRocaPorComando[client] = true;
    g_iRocaElegida[client]    = tipo;
    return Plugin_Handled;
}

Action Cmd_RocaDosManos(int client, int args) { return ElegirRocaPorComando(client, 3); }
Action Cmd_RocaLateral(int client, int args)  { return ElegirRocaPorComando(client, 2); }
Action Cmd_RocaUnaMano(int client, int args)  { return ElegirRocaPorComando(client, 1); }

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon)
{
    bool porComando = g_bRocaPorComando[client];
    g_bRocaPorComando[client] = false;

    if (!IsClientInGame(client) || IsFakeClient(client) || !EsTank(client))
        return Plugin_Continue;

    // No saltar mientras lanza la roca
    if ((buttons & IN_JUMP) && TankLanzandoRoca(client))
        buttons &= ~IN_JUMP;

    if (!g_cvRocas.BoolValue)
    {
        g_iRocaElegida[client] = 0;   // lanzamiento normal del juego
        return Plugin_Continue;
    }

    if (porComando)
    {
        buttons |= IN_ATTACK2;
    }
    else if (buttons & IN_RELOAD)
    {
        g_iRocaElegida[client] = 3;   // 2 manos por encima
        buttons |= IN_ATTACK2;
    }
    else if (buttons & IN_USE)
    {
        g_iRocaElegida[client] = 2;   // lateral
        buttons |= IN_ATTACK2;
    }
    else
    {
        g_iRocaElegida[client] = 1;   // clic derecho normal = 1 mano por encima
    }
    return Plugin_Continue;
}

// No golpear y lanzar roca a la vez
public Action L4D_OnCThrowActivate(int ability)
{
    if (!IsValidEntity(ability))
        return Plugin_Continue;

    int client = GetEntPropEnt(ability, Prop_Data, "m_hOwnerEntity");
    if (client > 0 && client <= MaxClients && IsClientInGame(client) && (GetClientButtons(client) & IN_ATTACK))
        return Plugin_Handled;
    return Plugin_Continue;
}

// El juego elige la animacion del ataque: si es una roca, se usa la elegida
public Action L4D2_OnSelectTankAttack(int client, int &sequence)
{
    if (!g_cvRocas.BoolValue || client < 1 || client > MaxClients)
        return Plugin_Continue;

    if (sequence > 48 && g_iRocaElegida[client] > 0)
    {
        sequence = g_iRocaElegida[client] + 48;
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

bool TankLanzandoRoca(int client)
{
    int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (ability == -1 || !IsValidEntity(ability))
        return false;

    // Mismos offsets que ZoneMod (a partir de m_hasBeenUsed de CThrow)
    static int offTimer = -1, offSeleccion = -1;
    if (offTimer == -1)
    {
        int base = FindSendPropInfo("CThrow", "m_hasBeenUsed");
        if (base <= 0)
            return false;
        offTimer     = base + 4;
        offSeleccion = base + 28;
    }

    CountdownTimer ct = view_as<CountdownTimer>(GetEntityAddress(ability) + view_as<Address>(offTimer));
    bool activo = CTimer_HasStarted(ct) && !CTimer_IsElapsed(ct);
    return activo || GetEntData(ability, offSeleccion, 1) > 0;
}
