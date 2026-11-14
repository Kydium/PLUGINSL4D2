#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "2.0.0"

ConVar g_cvEnabled;
ConVar g_cvUmbral;     // ping real por encima del cual NO se toca (default 100)
ConVar g_cvRangoMin;   // limite inferior del rango fake (default 40)
ConVar g_cvRangoMax;   // limite superior del rango fake (default 75)
ConVar g_cvJitter;     // variacion aleatoria adicional en cada tick (default 5)

Handle g_hTimer;
int    g_iPingFake[MAXPLAYERS + 1]; // valor base asignado a cada jugador

public Plugin myinfo =
{
    name        = "CL4D2 Fake Ping v2",
    author      = "Kydium",
    description = "Ping realista en scoreboard: rango fijo para lag bajo, ping real para lag alto",
    version     = PLUGIN_VERSION,
    url         = ""
};

public void OnPluginStart()
{
    g_cvEnabled  = CreateConVar("sm_fakeping_enabled",  "1",    "1 = activo, 0 = desactivo.", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvUmbral   = CreateConVar("sm_fakeping_umbral",   "100",  "Ping real por encima del cual se muestra el ping REAL sin modificar.", FCVAR_NOTIFY, true, 1.0, true, 500.0);
    g_cvRangoMin = CreateConVar("sm_fakeping_min",      "40",   "Ping minimo del rango fake para jugadores con buena conexion.", FCVAR_NOTIFY, true, 1.0, true, 200.0);
    g_cvRangoMax = CreateConVar("sm_fakeping_max",      "75",   "Ping maximo del rango fake para jugadores con buena conexion.", FCVAR_NOTIFY, true, 1.0, true, 200.0);
    g_cvJitter   = CreateConVar("sm_fakeping_jitter",   "5",    "Variacion aleatoria que se suma/resta en cada actualizacion (simula fluctuacion real).", FCVAR_NOTIFY, true, 0.0, true, 30.0);

    AutoExecConfig(true, "cl4d2_fakeping");

    HookConVarChange(g_cvEnabled, OnEnabledChanged);
}

public void OnPluginEnd()
{
    PararTimer();
    // Restaurar pings reales al descargar el plugin
    ActualizarPings(true);
}

public void OnClientConnected(int client)
{
    // Asignar un valor base aleatorio dentro del rango al conectar
    // (se recalcula si su ping real supera el umbral)
    g_iPingFake[client] = 0;
}

public void OnClientDisconnect(int client)
{
    g_iPingFake[client] = 0;
}

public void OnMapStart()
{
    if (g_cvEnabled.BoolValue)
        ArrancarTimer();
}

public void OnMapEnd()
{
    PararTimer();
}

void OnEnabledChanged(ConVar cv, const char[] oldVal, const char[] newVal)
{
    if (cv.BoolValue)
        ArrancarTimer();
    else
    {
        PararTimer();
        ActualizarPings(true); // restaurar pings reales
    }
}

void ArrancarTimer()
{
    PararTimer();
    g_hTimer = CreateTimer(0.8, Timer_ActualizarPings, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

void PararTimer()
{
    if (g_hTimer != null)
    {
        KillTimer(g_hTimer);
        g_hTimer = null;
    }
}

public Action Timer_ActualizarPings(Handle timer)
{
    ActualizarPings(false);
    return Plugin_Continue;
}

int ObtenerPlayerResource()
{
    int ent = FindEntityByClassname(-1, "terror_player_manager");
    if (ent == -1)
        ent = FindEntityByClassname(-1, "player_manager");
    return ent;
}

void ActualizarPings(bool restaurar)
{
    int pr_debug = ObtenerPlayerResource();
    if (pr_debug == -1)
    {
        LogMessage("[FakePing] ERROR: no se encontro terror_player_manager");
        return;
    }

    int    umbral  = g_cvUmbral.IntValue;
    int    rMin    = g_cvRangoMin.IntValue;
    int    rMax    = g_cvRangoMax.IntValue;
    int    jitter  = g_cvJitter.IntValue;

    // Asegurar que rMin <= rMax
    if (rMin > rMax) rMin = rMax;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i))
            continue;

        // Ping real del cliente (en segundos -> convertir a ms)
        float fLatencia = GetClientAvgLatency(i, NetFlow_Both);
        int   pingReal  = RoundToNearest(fLatencia * 1000.0);
        if (pingReal < 0) pingReal = 0;

        if (restaurar)
        {
            // Restaurar al real
            int pr = ObtenerPlayerResource();
            if (pr == -1) continue;
            SetEntProp(pr, Prop_Send, "m_iPing", pingReal, 4, i);
            continue;
        }

        int pingMostrar;

        if (pingReal >= umbral)
        {
            // Tiene lag de verdad: mostrar su ping real (con minimo jitter pa que no quede clavado)
            int variacion = (jitter > 0) ? GetRandomInt(-jitter / 2, jitter / 2) : 0;
            pingMostrar   = pingReal + variacion;
            if (pingMostrar < 0) pingMostrar = 0;
        }
        else
        {
            // Buena conexion: asignar valor base dentro del rango si no tiene uno aun
            if (g_iPingFake[i] == 0)
                g_iPingFake[i] = GetRandomInt(rMin, rMax);

            // Aplicar jitter sobre su base asignada (para que "respire" de forma realista)
            int variacion = (jitter > 0) ? GetRandomInt(-jitter, jitter) : 0;
            pingMostrar   = g_iPingFake[i] + variacion;

            // Mantener dentro del rango (el jitter no lo saca demasiado)
            if (pingMostrar < rMin - jitter) pingMostrar = rMin;
            if (pingMostrar > rMax + jitter) pingMostrar = rMax;
        }

        int pr = ObtenerPlayerResource();
        if (pr == -1) continue;
        SetEntProp(pr, Prop_Send, "m_iPing", pingMostrar, 4, i);
    }
}
