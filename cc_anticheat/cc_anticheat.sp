#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "1.0.0"
#define TEAM_SURVIVORS 2
#define TEAM_INFECTED  3

// ── Cvars ──────────────────────────────────────────────────────
ConVar g_cvHabilitado;
ConVar g_cvVelMax;            // velocidad horizontal máxima (u/s)
ConVar g_cvVelMuestras;       // cuántas muestras consecutivas antes de actuar
ConVar g_cvGarrazoMin;        // intervalo mínimo entre garrazos (segundos)
ConVar g_cvGarrazoGolpes;     // cuántos garrazos rápidos antes de actuar
ConVar g_cvDisparoVentana;    // ventana deslizante (seg) para medir cadencia
ConVar g_cvDisparoMargen;     // multiplicador de tolerancia sobre la cadencia real del arma
ConVar g_cvDisparoStrikes;    // ventanas infractoras antes de actuar
ConVar g_cvDisparoDecay;      // segundos sin infracción para borrar strikes
ConVar g_cvDisparoMinTiros;   // tiros mínimos en ventana para siquiera evaluar
ConVar g_cvPingMax;           // ping sobre el cual no se evalúa cadencia
ConVar g_cvAccion;            // 0=log, 1=kick, 2=ban temporal
ConVar g_cvBanMinutos;        // minutos de ban si accion=2
ConVar g_cvIntervaloChequeo;  // cada cuántos segundos revisar velocidad
ConVar g_cvInmunidadAdmin;    // admins inmunes al anticheat
ConVar g_cvNombreMaxCambios;  // cambios de nombre permitidos en la ventana
ConVar g_cvNombreVentana;     // ventana de tiempo (seg) para contar cambios

// ── Por jugador ────────────────────────────────────────────────
float  g_fUltimoGarrazo[MAXPLAYERS + 1];
int    g_iGarrazosRapidos[MAXPLAYERS + 1];

#define MAX_DISPAROS 96

float  g_fDisparos[MAXPLAYERS + 1][MAX_DISPAROS]; // timestamps ring buffer
int    g_iDisparoIdx[MAXPLAYERS + 1];             // índice circular
char   g_sArmaActual[MAXPLAYERS + 1][64];         // arma del último disparo
int    g_iStrikesDisparo[MAXPLAYERS + 1];         // infracciones acumuladas
float  g_fUltimoStrike[MAXPLAYERS + 1];           // cuándo fue el último strike
float  g_fGraciaHasta[MAXPLAYERS + 1];            // no evaluar hasta este momento

int    g_iMuestrasVelocidad[MAXPLAYERS + 1];

float  g_fNombreCambios[MAXPLAYERS + 1][10];  // timestamps de los últimos 10 cambios
int    g_iNombreCambioIdx[MAXPLAYERS + 1];     // índice circular
char   g_sNombreOriginal[MAXPLAYERS + 1][MAX_NAME_LENGTH]; // nombre al conectar

Handle g_hTimerVelocidad;

public Plugin myinfo =
{
    name        = "[CC] Anti-Cheat",
    author      = "Kydium",
    description = "Detecta speedhack, garrazos rápidos, disparo rápido y nombre spam",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/Kydium"
};

// ════════════════════════════════════════════════════════════════
//  INICIO
// ════════════════════════════════════════════════════════════════
public void OnPluginStart()
{
    g_cvHabilitado      = CreateConVar("sm_ac_habilitado",       "1",     "Habilitar anti-cheat (0/1)");
    g_cvVelMax          = CreateConVar("sm_ac_vel_max",          "550.0", "Velocidad horizontal máxima permitida (u/s). Charger llega a ~500");
    g_cvVelMuestras     = CreateConVar("sm_ac_vel_muestras",     "6",     "Muestras consecutivas sobre el límite antes de actuar");
    g_cvGarrazoMin      = CreateConVar("sm_ac_garrazo_min",      "0.25",  "Intervalo mínimo (seg) entre garrazos de infectado");
    g_cvGarrazoGolpes   = CreateConVar("sm_ac_garrazo_golpes",   "4",     "Garrazos rápidos consecutivos antes de actuar");
    g_cvDisparoVentana  = CreateConVar("sm_ac_disparo_ventana", "2.0",   "Ventana deslizante (seg) para medir cadencia. Más larga = los picos de lag se promedian");
    g_cvDisparoMargen   = CreateConVar("sm_ac_disparo_margen",  "1.7",   "Tolerancia sobre la cadencia real del arma (1.7 = permite 70% más rápido)");
    g_cvDisparoStrikes  = CreateConVar("sm_ac_disparo_strikes", "6",     "Ventanas infractoras acumuladas antes de actuar");
    g_cvDisparoDecay    = CreateConVar("sm_ac_disparo_decay",   "45.0",  "Segundos sin infracción para borrar los strikes acumulados");
    g_cvDisparoMinTiros = CreateConVar("sm_ac_disparo_mintiros","14",    "Tiros mínimos en la ventana para siquiera evaluar cadencia");
    g_cvPingMax         = CreateConVar("sm_ac_ping_max",        "180",   "Ping sobre el cual NO se evalúa cadencia (sus comandos llegan en ráfagas)");
    g_cvAccion          = CreateConVar("sm_ac_accion",           "1",     "Acción al detectar: 0=solo log, 1=kick, 2=ban temporal");
    g_cvBanMinutos      = CreateConVar("sm_ac_ban_min",          "30",    "Minutos de ban si acción=2");
    g_cvIntervaloChequeo = CreateConVar("sm_ac_intervalo",       "0.5",   "Intervalo (seg) entre chequeos de velocidad");
    g_cvInmunidadAdmin  = CreateConVar("sm_ac_inmunidad_admin",  "1",     "Admins con flag ADMFLAG_ROOT son inmunes (0/1)");
    g_cvNombreMaxCambios = CreateConVar("sm_ac_nombre_max",     "3",     "Cambios de nombre permitidos en la ventana de tiempo");
    g_cvNombreVentana   = CreateConVar("sm_ac_nombre_ventana",  "30.0",  "Ventana de tiempo (seg) para contar cambios de nombre");

    HookEvent("player_hurt",  Event_PlayerHurt);
    HookEvent("weapon_fire",  Event_WeaponFire);
    HookEvent("player_spawn", Event_Gracia);
    HookEvent("round_start",  Event_RoundStart, EventHookMode_PostNoCopy);

    AutoExecConfig(true, "cc_anticheat");

    RegAdminCmd("sm_ac_estado", Cmd_Estado, ADMFLAG_ROOT, "Muestra contadores anti-cheat de todos los jugadores");
}

public void OnMapStart()
{
    if (g_hTimerVelocidad != null)
    {
        KillTimer(g_hTimerVelocidad);
        g_hTimerVelocidad = null;
    }

    float intervalo = g_cvIntervaloChequeo.FloatValue;
    if (intervalo < 0.1) intervalo = 0.5;
    g_hTimerVelocidad = CreateTimer(intervalo, Timer_ChequearVelocidad, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnClientPutInServer(int client)
{
    ResetCliente(client);
    if (!IsFakeClient(client))
        GetClientName(client, g_sNombreOriginal[client], sizeof(g_sNombreOriginal[]));
}

public void OnClientDisconnect(int client)
{
    ResetCliente(client);
}

void ResetCliente(int client)
{
    g_fUltimoGarrazo[client]    = 0.0;
    g_iGarrazosRapidos[client]  = 0;
    g_iMuestrasVelocidad[client] = 0;
    g_iDisparoIdx[client]       = 0;
    g_iStrikesDisparo[client]   = 0;
    g_fUltimoStrike[client]     = 0.0;
    g_fGraciaHasta[client]      = 0.0;
    g_sArmaActual[client][0]    = '\0';
    for (int i = 0; i < MAX_DISPAROS; i++)
        g_fDisparos[client][i] = 0.0;
    g_iNombreCambioIdx[client]  = 0;
    g_sNombreOriginal[client][0] = '\0';
    for (int i = 0; i < 10; i++)
        g_fNombreCambios[client][i] = 0.0;
}

// ════════════════════════════════════════════════════════════════
//  DETECCIÓN 1: VELOCIDAD
// ════════════════════════════════════════════════════════════════
public Action Timer_ChequearVelocidad(Handle timer)
{
    if (!g_cvHabilitado.BoolValue) return Plugin_Continue;

    float velMax = g_cvVelMax.FloatValue;
    int   muestrasMax = g_cvVelMuestras.IntValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i) || IsFakeClient(i))
            continue;

        if (EsInmune(i)) continue;

        // Ignorar si el jugador está siendo arrastrado/montado/cargado/incapacitado
        if (EstaEnEstadoEspecial(i)) continue;

        float vel[3];
        GetEntPropVector(i, Prop_Data, "m_vecVelocity", vel);

        // Solo velocidad horizontal (ignorar Z para caídas/saltos)
        float velH = SquareRoot(vel[0] * vel[0] + vel[1] * vel[1]);

        if (velH > velMax)
        {
            g_iMuestrasVelocidad[i]++;
            if (g_iMuestrasVelocidad[i] >= muestrasMax)
            {
                char nombre[MAX_NAME_LENGTH];
                GetClientName(i, nombre, sizeof(nombre));
                char steamId[32];
                GetClientAuthId(i, AuthId_Steam2, steamId, sizeof(steamId));

                LogMessage("[AC] SPEEDHACK: %s (%s) vel=%.0f u/s (max=%.0f) x%d muestras",
                    nombre, steamId, velH, velMax, g_iMuestrasVelocidad[i]);

                Castigar(i, "Speedhack detectado (velocidad: %.0f u/s)", velH);
                ResetCliente(i);
            }
        }
        else
        {
            // Reset progresivo: si baja la velocidad, reducir contador
            if (g_iMuestrasVelocidad[i] > 0)
                g_iMuestrasVelocidad[i]--;
        }
    }

    return Plugin_Continue;
}

// Detectar si el jugador está en un estado que puede causar velocidad alta legítima
bool EstaEnEstadoEspecial(int client)
{
    int team = GetClientTeam(client);

    if (team == TEAM_SURVIVORS)
    {
        // Incapacitado, colgado, siendo arrastrado por smoker, montado por jockey, cargado por charger
        if (GetEntProp(client, Prop_Send, "m_isIncapacitated") == 1)
            return true;
        if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge") == 1)
            return true;
        // Siendo cargado por un charger
        if (GetEntProp(client, Prop_Send, "m_pummelAttacker") > 0)
            return true;
        if (GetEntProp(client, Prop_Send, "m_carryAttacker") > 0)
            return true;
        if (GetEntProp(client, Prop_Send, "m_tongueOwner") > 0)
            return true;
        if (GetEntProp(client, Prop_Send, "m_jockeyAttacker") > 0)
            return true;
        if (GetEntProp(client, Prop_Send, "m_pounceAttacker") > 0)
            return true;
    }
    else if (team == TEAM_INFECTED)
    {
        int zClass = GetEntProp(client, Prop_Send, "m_zombieClass");
        // 6 = Charger — puede estar cargando legítimamente
        if (zClass == 6)
        {
            int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
            if (ability != -1)
            {
                // Si la habilidad está activa (charging), ignorar
                if (GetEntProp(ability, Prop_Send, "m_isCharging") == 1)
                    return true;
            }
        }
        // 3 = Hunter — puede estar en pounce
        if (zClass == 3)
        {
            int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
            if (ability != -1)
            {
                // Hunter lunging
                if (HasEntProp(ability, Prop_Send, "m_isLunging") && GetEntProp(ability, Prop_Send, "m_isLunging") == 1)
                    return true;
            }
        }
        // 8 = Tank — el golpe de Tank puede lanzar al propio Tank? No, pero su velocidad base es alta
        // Los Tanks no deberían superar 550 de todas formas
    }

    return false;
}

// ════════════════════════════════════════════════════════════════
//  DETECCIÓN 2: GARRAZOS RÁPIDOS (INFECTADO)
// ════════════════════════════════════════════════════════════════
public void Event_PlayerHurt(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvHabilitado.BoolValue) return;

    int atacante = GetClientOfUserId(event.GetInt("attacker"));
    int victima  = GetClientOfUserId(event.GetInt("userid"));

    if (atacante < 1 || atacante > MaxClients || !IsClientInGame(atacante))
        return;
    if (IsFakeClient(atacante)) return;
    if (EsInmune(atacante)) return;

    // Solo detectar ataques de infectado contra superviviente
    if (GetClientTeam(atacante) != TEAM_INFECTED) return;
    if (victima < 1 || victima > MaxClients || !IsClientInGame(victima)) return;
    if (GetClientTeam(victima) != TEAM_SURVIVORS) return;

    // Verificar que es un ataque claw (no habilidad especial)
    char arma[64];
    event.GetString("weapon", arma, sizeof(arma));

    // Las garras/claws de infectados: vacío, "tank_claw", "boomer_claw", 
    // "hulk_pound" (tank pound), "smoker_claw", "hunter_claw", "spitter_claw", "jockey_claw", "charger_claw"
    // Las habilidades especiales tienen otros nombres: "tongue", "ability_charge", etc.
    if (StrContains(arma, "claw") == -1 &&
        StrContains(arma, "pound") == -1 &&
        strlen(arma) != 0)  // arma vacía también puede ser garra
    {
        return;
    }

    float ahora = GetEngineTime();
    float intervaloMin = g_cvGarrazoMin.FloatValue;
    int   golpesMax = g_cvGarrazoGolpes.IntValue;

    if (g_fUltimoGarrazo[atacante] > 0.0)
    {
        float delta = ahora - g_fUltimoGarrazo[atacante];
        if (delta < intervaloMin && delta > 0.0)
        {
            g_iGarrazosRapidos[atacante]++;
            if (g_iGarrazosRapidos[atacante] >= golpesMax)
            {
                char nombreAtk[MAX_NAME_LENGTH], steamId[32];
                GetClientName(atacante, nombreAtk, sizeof(nombreAtk));
                GetClientAuthId(atacante, AuthId_Steam2, steamId, sizeof(steamId));

                LogMessage("[AC] GARRAZO RÁPIDO: %s (%s) — %d golpes en <%.2fs cada uno",
                    nombreAtk, steamId, g_iGarrazosRapidos[atacante], intervaloMin);

                Castigar(atacante, "Ataque rápido detectado (%d garrazos en intervalo anormal)", g_iGarrazosRapidos[atacante]);
                ResetCliente(atacante);
                return;
            }
        }
        else
        {
            // Intervalo normal, resetear
            g_iGarrazosRapidos[atacante] = 0;
        }
    }

    g_fUltimoGarrazo[atacante] = ahora;
}

// ════════════════════════════════════════════════════════════════
//  DETECCIÓN 3: DISPARO RÁPIDO (SUPERVIVIENTE)
//  Método: ventana deslizante contra la cadencia REAL del arma.
//  Robusto ante lag, ráfagas de comandos y pistolas duales.
// ════════════════════════════════════════════════════════════════

// Cadencia máxima real de cada arma en disparos por segundo.
// Valores tomados del ciclo de disparo del juego; el margen se aplica aparte.
float CadenciaMaximaArma(const char[] arma)
{
    // ── Subfusiles (ciclo 0.055s = 18.2 dps) ──
    if (StrEqual(arma, "smg"))              return 18.2;
    if (StrEqual(arma, "smg_silenced"))     return 18.2;
    if (StrEqual(arma, "smg_mp5"))          return 18.2;

    // ── Fusiles ──
    if (StrEqual(arma, "rifle"))            return 18.2;  // M16, ciclo 0.055s
    if (StrEqual(arma, "rifle_ak47"))       return 11.7;  // ciclo 0.0857s
    if (StrEqual(arma, "rifle_sg552"))      return 15.0;  // ciclo 0.0666s
    if (StrEqual(arma, "rifle_desert"))     return 20.0;  // SCAR: ráfaga de 3 muy junta
    if (StrEqual(arma, "rifle_m60"))        return 13.3;  // ciclo 0.075s

    // ── Pistolas (semiautomáticas: limitadas por el clic del jugador) ──
    // Las duales disparan AMBAS por pulsación = 2 eventos casi simultáneos.
    if (StrEqual(arma, "pistol"))           return 24.0;  // generoso por las duales
    if (StrEqual(arma, "pistol_magnum"))    return 12.0;

    // ── Francotiradores ──
    if (StrEqual(arma, "hunting_rifle"))    return 10.0;
    if (StrEqual(arma, "sniper_military"))  return 10.0;
    if (StrEqual(arma, "sniper_scout"))     return 8.0;
    if (StrEqual(arma, "sniper_awp"))       return 8.0;

    // ── Escopetas ──
    if (StrEqual(arma, "pumpshotgun"))      return 4.0;
    if (StrEqual(arma, "shotgun_chrome"))   return 4.0;
    if (StrEqual(arma, "autoshotgun"))      return 7.0;
    if (StrEqual(arma, "shotgun_spas"))     return 7.0;

    // ── Otros ──
    if (StrEqual(arma, "grenade_launcher")) return 3.0;

    // Arma desconocida (mod, reemplazo, arma nueva): límite muy permisivo
    return 25.0;
}

// Armas que NO deben evaluarse por cadencia
bool ArmaIgnorada(const char[] arma)
{
    if (strlen(arma) == 0) return true;

    // Cuerpo a cuerpo: la motosierra dispara weapon_fire continuamente al revolucionar
    if (StrContains(arma, "melee") != -1)   return true;
    if (StrEqual(arma, "chainsaw"))         return true;
    if (StrEqual(arma, "knife"))            return true;
    if (StrEqual(arma, "baseball_bat"))     return true;
    if (StrEqual(arma, "cricket_bat"))      return true;
    if (StrEqual(arma, "crowbar"))          return true;
    if (StrEqual(arma, "electric_guitar"))  return true;
    if (StrEqual(arma, "fireaxe"))          return true;
    if (StrEqual(arma, "frying_pan"))       return true;
    if (StrEqual(arma, "golfclub"))         return true;
    if (StrEqual(arma, "katana"))           return true;
    if (StrEqual(arma, "machete"))          return true;
    if (StrEqual(arma, "tonfa"))            return true;
    if (StrEqual(arma, "shovel"))           return true;
    if (StrEqual(arma, "pitchfork"))        return true;
    if (StrEqual(arma, "riotshield"))       return true;

    // Lanzables y objetos: no tienen cadencia sostenida
    if (StrEqual(arma, "pipe_bomb"))        return true;
    if (StrEqual(arma, "molotov"))          return true;
    if (StrEqual(arma, "vomitjar"))         return true;
    if (StrEqual(arma, "first_aid_kit"))    return true;
    if (StrEqual(arma, "defibrillator"))    return true;
    if (StrEqual(arma, "pain_pills"))       return true;
    if (StrEqual(arma, "adrenaline"))       return true;
    if (StrEqual(arma, "upgradepack_incendiary")) return true;
    if (StrEqual(arma, "upgradepack_explosive"))  return true;
    if (StrEqual(arma, "gascan"))           return true;
    if (StrEqual(arma, "propanetank"))      return true;
    if (StrEqual(arma, "oxygentank"))       return true;
    if (StrEqual(arma, "fireworkcrate"))    return true;

    return false;
}

public void Event_WeaponFire(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvHabilitado.BoolValue) return;

    int cliente = GetClientOfUserId(event.GetInt("userid"));
    if (cliente < 1 || cliente > MaxClients || !IsClientInGame(cliente))
        return;
    if (IsFakeClient(cliente)) return;
    if (EsInmune(cliente)) return;
    if (GetClientTeam(cliente) != TEAM_SURVIVORS) return;

    char arma[64];
    event.GetString("weapon", arma, sizeof(arma));
    if (ArmaIgnorada(arma)) return;

    float ahora = GetEngineTime();

    // ── FILTRO 1: si cambió de arma, reiniciar el historial ──
    // Cadencias distintas no se pueden mezclar en la misma ventana.
    if (!StrEqual(g_sArmaActual[cliente], arma))
    {
        strcopy(g_sArmaActual[cliente], sizeof(g_sArmaActual[]), arma);
        g_iDisparoIdx[cliente] = 0;
        for (int i = 0; i < MAX_DISPAROS; i++)
            g_fDisparos[cliente][i] = 0.0;
        // Pequeña gracia tras cambiar de arma
        g_fGraciaHasta[cliente] = ahora + 1.0;
    }

    // Registrar el disparo SIEMPRE (aunque estemos en gracia)
    g_fDisparos[cliente][g_iDisparoIdx[cliente] % MAX_DISPAROS] = ahora;
    g_iDisparoIdx[cliente]++;

    // ── FILTRO 2: período de gracia (spawn, ronda nueva, cambio de arma) ──
    if (ahora < g_fGraciaHasta[cliente]) return;

    // ── FILTRO 3: el servidor está laggeando ──
    // Con frames largos se acumulan comandos y todo parece instantáneo.
    if (GetGameFrameTime() > 0.06) return;

    // ── FILTRO 4: el jugador tiene ping alto ──
    // Sus comandos llegan en ráfagas y el servidor los procesa juntos.
    float pingMax = g_cvPingMax.FloatValue;
    if (pingMax > 0.0)
    {
        float ping = GetClientAvgLatency(cliente, NetFlow_Outgoing) * 1000.0;
        if (ping > pingMax) return;
    }

    // ── MEDICIÓN: contar disparos dentro de la ventana deslizante ──
    float ventana = g_cvDisparoVentana.FloatValue;
    if (ventana < 0.5) ventana = 2.0;

    int enVentana = 0;
    float masAntiguo = ahora;

    for (int i = 0; i < MAX_DISPAROS; i++)
    {
        float t = g_fDisparos[cliente][i];
        if (t <= 0.0) continue;
        if ((ahora - t) <= ventana)
        {
            enVentana++;
            if (t < masAntiguo) masAntiguo = t;
        }
    }

    // ── FILTRO 5: muestra insuficiente ──
    // Con pocos tiros el cálculo de cadencia no es confiable.
    int minTiros = g_cvDisparoMinTiros.IntValue;
    if (enVentana < minTiros) return;

    // ── FILTRO 6: el tiempo medido debe ser significativo ──
    // Si todos los tiros caen en un instante, es una ráfaga de red, no cadencia.
    float lapso = ahora - masAntiguo;
    if (lapso < 0.4) return;

    // Cadencia observada vs. permitida
    float cadenciaObs = float(enVentana - 1) / lapso;
    float cadenciaMax = CadenciaMaximaArma(arma) * g_cvDisparoMargen.FloatValue;

    if (cadenciaObs <= cadenciaMax)
        return;

    // ── INFRACCIÓN ──
    // Decay: si pasó mucho desde el último strike, empezar de cero.
    float decay = g_cvDisparoDecay.FloatValue;
    if (g_fUltimoStrike[cliente] > 0.0 && (ahora - g_fUltimoStrike[cliente]) > decay)
        g_iStrikesDisparo[cliente] = 0;

    g_iStrikesDisparo[cliente]++;
    g_fUltimoStrike[cliente] = ahora;

    char nombreCl[MAX_NAME_LENGTH], steamId[32];
    GetClientName(cliente, nombreCl, sizeof(nombreCl));
    GetClientAuthId(cliente, AuthId_Steam2, steamId, sizeof(steamId));

    LogMessage("[AC] Cadencia alta: %s (%s) arma=%s obs=%.1f dps max=%.1f dps tiros=%d lapso=%.2fs strike=%d/%d",
        nombreCl, steamId, arma, cadenciaObs, cadenciaMax, enVentana, lapso,
        g_iStrikesDisparo[cliente], g_cvDisparoStrikes.IntValue);

    if (g_iStrikesDisparo[cliente] >= g_cvDisparoStrikes.IntValue)
    {
        LogMessage("[AC] DISPARO RÁPIDO CONFIRMADO: %s (%s) arma=%s %.1f dps (max %.1f)",
            nombreCl, steamId, arma, cadenciaObs, cadenciaMax);

        Castigar(cliente, "Cadencia de disparo anormal (%.0f disparos/seg con %s, máximo %.0f)",
            cadenciaObs, arma, cadenciaMax);
        ResetCliente(cliente);
        return;
    }

    // Tras registrar un strike, limpiar la ventana para no contar
    // los mismos disparos otra vez en el siguiente evento.
    g_iDisparoIdx[cliente] = 0;
    for (int i = 0; i < MAX_DISPAROS; i++)
        g_fDisparos[cliente][i] = 0.0;
}

// ── Períodos de gracia ──────────────────────────────────────────
public void Event_Gracia(Event event, const char[] name, bool dontBroadcast)
{
    int cliente = GetClientOfUserId(event.GetInt("userid"));
    if (cliente < 1 || cliente > MaxClients) return;
    if (!IsClientInGame(cliente)) return;

    g_fGraciaHasta[cliente] = GetEngineTime() + 3.0;
    g_iDisparoIdx[cliente] = 0;
    for (int i = 0; i < MAX_DISPAROS; i++)
        g_fDisparos[cliente][i] = 0.0;
}

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    float hasta = GetEngineTime() + 5.0;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_fGraciaHasta[i] = hasta;
        g_iDisparoIdx[i] = 0;
        for (int j = 0; j < MAX_DISPAROS; j++)
            g_fDisparos[i][j] = 0.0;
    }
}

// ════════════════════════════════════════════════════════════════
//  DETECCIÓN 4: CAMBIO DE NOMBRE SPAM
// ════════════════════════════════════════════════════════════════
public void OnClientSettingsChanged(int client)
{
    if (!g_cvHabilitado.BoolValue) return;
    if (client < 1 || client > MaxClients) return;
    if (!IsClientInGame(client) || IsFakeClient(client)) return;
    if (EsInmune(client)) return;

    // Verificar si el nombre cambió
    char nombreActual[MAX_NAME_LENGTH];
    GetClientName(client, nombreActual, sizeof(nombreActual));

    // Si no tenemos nombre original aún, guardar y salir
    if (g_sNombreOriginal[client][0] == '\0')
    {
        strcopy(g_sNombreOriginal[client], sizeof(g_sNombreOriginal[]), nombreActual);
        return;
    }

    // Si el nombre no cambió, ignorar (settings changed puede disparar por otras cosas)
    if (StrEqual(g_sNombreOriginal[client], nombreActual))
        return;

    // Nombre cambió — registrar timestamp
    float ahora = GetEngineTime();
    int idx = g_iNombreCambioIdx[client] % 10;
    g_fNombreCambios[client][idx] = ahora;
    g_iNombreCambioIdx[client]++;

    // Actualizar nombre guardado
    char steamId[32];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    LogMessage("[AC] Cambio de nombre: %s -> %s (%s)", g_sNombreOriginal[client], nombreActual, steamId);
    strcopy(g_sNombreOriginal[client], sizeof(g_sNombreOriginal[]), nombreActual);

    // Contar cambios dentro de la ventana de tiempo
    float ventana = g_cvNombreVentana.FloatValue;
    int maxCambios = g_cvNombreMaxCambios.IntValue;
    int conteo = 0;

    for (int i = 0; i < 10; i++)
    {
        if (g_fNombreCambios[client][i] > 0.0 && (ahora - g_fNombreCambios[client][i]) <= ventana)
            conteo++;
    }

    if (conteo >= maxCambios)
    {
        LogMessage("[AC] NOMBRE SPAM: %s (%s) — %d cambios en %.0fs",
            nombreActual, steamId, conteo, ventana);

        Castigar(client, "Cambio de nombre spam (%d cambios en %.0fs)", conteo, ventana);
        ResetCliente(client);
    }
}

// ════════════════════════════════════════════════════════════════
//  CASTIGO
// ════════════════════════════════════════════════════════════════
void Castigar(int client, const char[] formato, any ...)
{
    char mensaje[256];
    VFormat(mensaje, sizeof(mensaje), formato, 3);

    char nombre[MAX_NAME_LENGTH];
    GetClientName(client, nombre, sizeof(nombre));

    // Anunciar a todos
    PrintToChatAll("\x04[AC] \x01%s fue detectado: \x05%s", nombre, mensaje);

    int accion = g_cvAccion.IntValue;

    if (accion == 1)
    {
        KickClient(client, "[Anti-Cheat] %s", mensaje);
    }
    else if (accion == 2)
    {
        int minutos = g_cvBanMinutos.IntValue;
        char steamId[32];
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

        BanClient(client, minutos, BANFLAG_AUTHID, "[Anti-Cheat] %s", mensaje, "cc_anticheat");
    }
}

// ════════════════════════════════════════════════════════════════
//  UTILIDADES
// ════════════════════════════════════════════════════════════════
bool EsInmune(int client)
{
    if (!g_cvInmunidadAdmin.BoolValue) return false;
    return CheckCommandAccess(client, "sm_ac_inmune", ADMFLAG_ROOT, true);
}

// ════════════════════════════════════════════════════════════════
//  COMANDO ADMIN: VER ESTADO
// ════════════════════════════════════════════════════════════════
public Action Cmd_Estado(int client, int args)
{
    ReplyToCommand(client, "─── Anti-Cheat Estado ───");
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;

        char nombre[MAX_NAME_LENGTH];
        GetClientName(i, nombre, sizeof(nombre));

        // Contar cambios de nombre recientes
        float ahora = GetEngineTime();
        float ventana = g_cvNombreVentana.FloatValue;
        int cambiosNombre = 0;
        for (int j = 0; j < 10; j++)
        {
            if (g_fNombreCambios[i][j] > 0.0 && (ahora - g_fNombreCambios[i][j]) <= ventana)
                cambiosNombre++;
        }

        char armaMostrar[64];
        if (g_sArmaActual[i][0] == '\0')
            strcopy(armaMostrar, sizeof(armaMostrar), "-");
        else
            strcopy(armaMostrar, sizeof(armaMostrar), g_sArmaActual[i]);

        ReplyToCommand(client, "%s — vel:%d  garr:%d  disp:%d/%d  nombre:%d  arma:%s",
            nombre,
            g_iMuestrasVelocidad[i],
            g_iGarrazosRapidos[i],
            g_iStrikesDisparo[i],
            g_cvDisparoStrikes.IntValue,
            cambiosNombre,
            armaMostrar);
    }
    return Plugin_Handled;
}
