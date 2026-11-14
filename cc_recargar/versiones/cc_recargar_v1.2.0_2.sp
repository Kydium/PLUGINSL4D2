#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdkhooks>
#include <sdktools>

#define PLUGIN_VERSION "1.2.0"

public Plugin myinfo =
{
    name        = "CC Recargar",
    author      = "ClubCampestre",
    description = "Preserva balas del clip si se interrumpe la recarga (culatazo o cambio de arma)",
    version     = PLUGIN_VERSION,
    url         = ""
};

bool g_bPrevReload[MAXPLAYERS + 1];
int  g_iPrevClip[MAXPLAYERS + 1];
int  g_iPrevReserve[MAXPLAYERS + 1];   // reserva del frame anterior
int  g_iSavedClip[MAXPLAYERS + 1];
int  g_iSavedReserve[MAXPLAYERS + 1];  // reserva guardada al inicio de recarga
int  g_iAmmoType[MAXPLAYERS + 1];      // tipo de munición del arma
int  g_iLastWeapon[MAXPLAYERS + 1];

// ─────────────────────────────────────────────────────────────
// Inicialización
// ─────────────────────────────────────────────────────────────

public void OnPluginStart()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i))
            OnClientPutInServer(i);
    }
}

public void OnMapStart()
{
    for (int i = 1; i <= MaxClients; i++)
        ResetState(i);
}

public void OnClientPutInServer(int client)
{
    ResetState(client);
    SDKHook(client, SDKHook_PostThinkPost, OnPostThinkPost);
}

public void OnClientDisconnect(int client)
{
    SDKUnhook(client, SDKHook_PostThinkPost, OnPostThinkPost);
    ResetState(client);
}

void ResetState(int client)
{
    g_bPrevReload[client]  = false;
    g_iPrevClip[client]    = 0;
    g_iPrevReserve[client] = 0;
    g_iSavedClip[client]   = 0;
    g_iSavedReserve[client]= 0;
    g_iAmmoType[client]    = -1;
    g_iLastWeapon[client]  = -1;
}

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

int GetReserve(int client, int ammoType)
{
    if (ammoType < 0) return 0;
    return GetEntProp(client, Prop_Send, "m_iAmmo", 4, ammoType);
}

void SetReserve(int client, int ammoType, int value)
{
    if (ammoType < 0) return;
    SetEntProp(client, Prop_Send, "m_iAmmo", value, 4, ammoType);
}

// Restaura clip y reserva al estado previo al inicio de la recarga
void RestoreAmmo(int client, int weapon)
{
    if (g_iSavedClip[client] <= 0) return;
    SetEntProp(weapon, Prop_Data, "m_iClip1", g_iSavedClip[client]);
    SetReserve(client, g_iAmmoType[client], g_iSavedReserve[client]);
    g_iSavedClip[client]    = 0;
    g_iSavedReserve[client] = 0;
}

// ─────────────────────────────────────────────────────────────
// Lógica principal — frame a frame
// ─────────────────────────────────────────────────────────────

public void OnPostThinkPost(int client)
{
    if (!IsClientInGame(client) || !IsPlayerAlive(client))
        return;

    if (GetClientTeam(client) != 2)
        return;

    int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
    if (weapon == -1 || !IsValidEntity(weapon))
    {
        g_bPrevReload[client] = false;
        return;
    }

    // ── Cambio de arma ───────────────────────────────────────
    if (weapon != g_iLastWeapon[client])
    {
        // Si estábamos recargando el arma anterior, restaurar clip Y reserva
        if (g_bPrevReload[client] && g_iLastWeapon[client] != -1)
        {
            int oldWeapon = g_iLastWeapon[client];
            if (IsValidEntity(oldWeapon))
            {
                int oldClip = GetEntProp(oldWeapon, Prop_Data, "m_iClip1");
                if (oldClip == 0)
                    RestoreAmmo(client, oldWeapon);
            }
        }

        g_bPrevReload[client]  = false;
        g_iPrevClip[client]    = 0;
        g_iPrevReserve[client] = 0;
        g_iSavedClip[client]   = 0;
        g_iSavedReserve[client]= 0;
        g_iAmmoType[client]    = -1;
        g_iLastWeapon[client]  = weapon;
        return;
    }

    // Armas sin clip (cuerpo a cuerpo, etc.)
    int iCurrClip = GetEntProp(weapon, Prop_Data, "m_iClip1");
    if (iCurrClip == -1)
    {
        g_bPrevReload[client] = false;
        return;
    }

    int iAmmoType   = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
    int iCurrReserve = GetReserve(client, iAmmoType);

    bool bCurrReload = view_as<bool>(GetEntProp(weapon, Prop_Data, "m_bInReload"));

    // ── Inicio de recarga ────────────────────────────────────
    if (!g_bPrevReload[client] && bCurrReload)
    {
        // Guardar clip Y reserva del frame anterior (antes de que el juego los modifique)
        g_iSavedClip[client]    = g_iPrevClip[client];
        g_iSavedReserve[client] = g_iPrevReserve[client];
        g_iAmmoType[client]     = iAmmoType;
    }
    // ── Fin de recarga (completada o interrumpida por culatazo)
    else if (g_bPrevReload[client] && !bCurrReload)
    {
        if (iCurrClip == 0 && g_iSavedClip[client] > 0)
            RestoreAmmo(client, weapon);
        else
        {
            g_iSavedClip[client]    = 0;
            g_iSavedReserve[client] = 0;
        }
    }

    // Actualizar estado previo
    g_bPrevReload[client]  = bCurrReload;
    g_iPrevClip[client]    = iCurrClip;
    g_iPrevReserve[client] = iCurrReserve;
}
