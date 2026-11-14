/**
 * L4D2 Team Balancer by MMR
 * Versión: 3.7.0
 *
 * Cambios v3.7.0:
 * - Quitado el timer de 1 segundo en AplicarBalanceo y sm_balance_simular.
 * - Todo se ejecuta de corrido sin delays.
 * - Quitado el comando sm_balance_diag (no implementado).
 *
 * Cambios v3.6.0: AplicarBalanceo replicaba simular con timer.
 * Cambios v3.5.0: Sin timer.
 * Cambios v3.4.0: 2 fases con timer.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#define PLUGIN_VERSION "3.7.0"
#define DEFAULT_MMR    1500
#define TEAM_SPEC      1
#define TEAM_SURVIVORS 2
#define TEAM_INFECTED  3
#define MAX_JUGADORES  18

public Plugin myinfo =
{
    name        = "L4D2 Team Balancer by MMR",
    author      = "Custom",
    description = "Balanceo de equipos basado en MMR para L4D2 Versus",
    version     = PLUGIN_VERSION,
    url         = ""
};

Database g_DB = null;

int  g_BalanceSurvivors[MAX_JUGADORES];
int  g_BalanceInfected[MAX_JUGADORES];
int  g_iBalanceSurvCount;
int  g_iBalanceInfCount;
bool g_bBalancePending;

public void OnPluginStart()
{
    RegAdminCmd("sm_balance",       Cmd_BalanceMenu,  ADMFLAG_GENERIC, "Abre el menú de balanceo MMR");
    RegAdminCmd("sm_bm",            Cmd_BalanceMenu,  ADMFLAG_GENERIC, "Alias corto del menú de balanceo");

    RegAdminCmd("sm_balance_show",  Cmd_BalanceShow,  ADMFLAG_GENERIC, "Sugiere el balanceo óptimo por MMR");
    RegAdminCmd("sm_balance_apply", Cmd_BalanceApply, ADMFLAG_GENERIC, "Aplica el último balanceo sugerido");
    RegAdminCmd("sm_balance_auto",  Cmd_BalanceAuto,  ADMFLAG_GENERIC, "Sugiere y aplica el balanceo automáticamente");
    RegAdminCmd("sm_balance_diff",  Cmd_BalanceDiff,  ADMFLAG_GENERIC, "Muestra la diferencia de MMR actual");
    RegAdminCmd("sm_balance_simular", Cmd_BalanceSimular, ADMFLAG_GENERIC, "Simula el flujo del balance");

    InitDatabase();
}

void InitDatabase()
{
    char sError[256];
    g_DB = SQLite_UseDatabase("l4d2_mmr", sError, sizeof(sError));
    if (g_DB == null)
        LogError("[Balance] No se pudo conectar a la DB del MMR: %s", sError);
    else
        LogMessage("[Balance] Conectado a la DB del MMR correctamente.");
}

int ObtenerMMR(int client)
{
    if (g_DB == null) return DEFAULT_MMR;

    char sSteamID[64];
    if (!GetClientAuthId(client, AuthId_Steam2, sSteamID, sizeof(sSteamID)))
        return DEFAULT_MMR;

    char sEscaped[128];
    SQL_EscapeString(g_DB, sSteamID, sEscaped, sizeof(sEscaped));
    char sQuery[256];
    Format(sQuery, sizeof(sQuery),
        "SELECT mmr FROM mmr_players WHERE steamid = '%s';", sEscaped);

    DBResultSet results = SQL_Query(g_DB, sQuery);
    if (results == null) return DEFAULT_MMR;

    int iMMR = DEFAULT_MMR;
    if (results.FetchRow())
        iMMR = results.FetchInt(0);

    delete results;
    return iMMR;
}

void CalcularBalanceo(int[] outSurvivors, int &outSurvCount,
                      int[] outInfected,  int &outInfCount)
{
    int iPlayers[MAX_JUGADORES];
    int iMMRs[MAX_JUGADORES];
    int iTotal = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i))   continue;
        if (!IsClientInGame(i)) continue;
        int iTeam = GetClientTeam(i);
        if (iTeam != TEAM_SURVIVORS && iTeam != TEAM_INFECTED) continue;
        iPlayers[iTotal] = i;
        iMMRs[iTotal]    = ObtenerMMR(i);
        iTotal++;
    }

    LogMessage("[Balance] CalcularBalanceo: %d humanos detectados", iTotal);

    // Ordenar por MMR descendente
    for (int i = 0; i < iTotal - 1; i++)
    {
        for (int j = 0; j < iTotal - i - 1; j++)
        {
            if (iMMRs[j] < iMMRs[j + 1])
            {
                int tmpMMR      = iMMRs[j];
                iMMRs[j]        = iMMRs[j + 1];
                iMMRs[j + 1]    = tmpMMR;
                int tmpPlayer   = iPlayers[j];
                iPlayers[j]     = iPlayers[j + 1];
                iPlayers[j + 1] = tmpPlayer;
            }
        }
    }

    int iGrupoA[MAX_JUGADORES];
    int iGrupoB[MAX_JUGADORES];
    int iCountA = 0;
    int iCountB = 0;
    int iMMRA = 0;
    int iMMRB = 0;
    int iMaxA = iTotal - (iTotal / 2);
    int iMaxB = iTotal / 2;

    for (int i = 0; i < iTotal; i++)
    {
        bool bPuedeIrA = (iCountA < iMaxA);
        bool bPuedeIrB = (iCountB < iMaxB);
        bool bIrA;

        if      (bPuedeIrA && !bPuedeIrB)  bIrA = true;
        else if (!bPuedeIrA && bPuedeIrB)  bIrA = false;
        else                                bIrA = (iMMRA <= iMMRB);

        if (bIrA)
        {
            iGrupoA[iCountA++] = iPlayers[i];
            iMMRA += iMMRs[i];
        }
        else
        {
            iGrupoB[iCountB++] = iPlayers[i];
            iMMRB += iMMRs[i];
        }
    }

    // Asignar el grupo de MAYOR MMR como Survivors
    if (iMMRA >= iMMRB)
    {
        for (int i = 0; i < iCountA; i++) outSurvivors[i] = iGrupoA[i];
        for (int i = 0; i < iCountB; i++) outInfected[i]  = iGrupoB[i];
        outSurvCount = iCountA;
        outInfCount  = iCountB;
    }
    else
    {
        for (int i = 0; i < iCountB; i++) outSurvivors[i] = iGrupoB[i];
        for (int i = 0; i < iCountA; i++) outInfected[i]  = iGrupoA[i];
        outSurvCount = iCountB;
        outInfCount  = iCountA;
    }

    LogMessage("[Balance] Resultado: Survivors=%d (MMR avg %d) | Infected=%d (MMR avg %d)",
        outSurvCount,
        outSurvCount > 0 ? (iMMRA >= iMMRB ? iMMRA / outSurvCount : iMMRB / outSurvCount) : 0,
        outInfCount,
        outInfCount > 0 ? (iMMRA >= iMMRB ? iMMRB / outInfCount : iMMRA / outInfCount) : 0);
}

// =============================================
// PromedioMMR - retorna 0 si esta vacio
// =============================================
float PromedioMMR(int[] players, int count)
{
    if (count == 0) return 0.0;
    int iTotal = 0;
    for (int i = 0; i < count; i++)
        iTotal += ObtenerMMR(players[i]);
    return float(iTotal) / float(count);
}

int EncontrarBotSurvivor()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i))                  continue;
        if (!IsFakeClient(i))                    continue;
        if (GetClientTeam(i) != TEAM_SURVIVORS)  continue;
        return i;
    }
    return -1;
}

// =============================================
// MoverASurvivors - con logs detallados
// =============================================
bool MoverASurvivors(int client)
{
    if (GetClientTeam(client) == TEAM_SURVIVORS)
    {
        LogMessage("[Balance] %N ya esta en Survivors, no se mueve", client);
        return true;
    }

    LogMessage("[Balance] Intentando mover %N a Survivors...", client);

    // Paso 1: mover a spectator
    LogMessage("[Balance]   Paso 1: ChangeClientTeam(%N, SPEC)", client);
    ChangeClientTeam(client, TEAM_SPEC);

    // Verificar
    int iTeamAhora = GetClientTeam(client);
    LogMessage("[Balance]   %N esta ahora en team %d (esperado: 1=spec)", client, iTeamAhora);

    // Paso 2: buscar bot survivor
    int iBot = EncontrarBotSurvivor();
    if (iBot == -1)
    {
        LogError("[Balance] No hay bots survivors disponibles para %N", client);
        return false;
    }
    LogMessage("[Balance]   Paso 2: Bot survivor encontrado: client #%d", iBot);

    // Paso 3: SetHumanSpec
    LogMessage("[Balance]   Paso 3: L4D_SetHumanSpec(bot=%d, human=%N)", iBot, client);
    L4D_SetHumanSpec(iBot, client);

    // Paso 4: TakeOverBot
    LogMessage("[Balance]   Paso 4: L4D_TakeOverBot(%N)", client);
    L4D_TakeOverBot(client);

    // Verificar resultado
    int iTeamFinal = GetClientTeam(client);
    LogMessage("[Balance]   Team final: %d (esperado: 2=Survivors)", iTeamFinal);

    if (iTeamFinal == TEAM_SURVIVORS)
    {
        LogMessage("[Balance] %N MOVIDO EXITOSAMENTE a Survivors", client);
        return true;
    }
    else
    {
        LogError("[Balance] FALLO al mover %N a Survivors. Team actual: %d", client, iTeamFinal);
        // Intento de recuperacion: forzar ChangeClientTeam
        LogMessage("[Balance]   Intento de recuperacion: ChangeClientTeam directo");
        ChangeClientTeam(client, TEAM_SURVIVORS);
        return (GetClientTeam(client) == TEAM_SURVIVORS);
    }
}

void MostrarPropuesta(int client,
                      int[] survivors, int survCount,
                      int[] infected,  int infCount)
{
    float fAvgSurv = PromedioMMR(survivors, survCount);
    float fAvgInf  = PromedioMMR(infected,  infCount);
    float fDiff    = fAvgSurv - fAvgInf;
    if (fDiff < 0.0) fDiff = -fDiff;

    PrintToChat(client, "\x04[Balance]\x01 \x05══════════════════════");
    PrintToChat(client, "\x04[Balance]\x01   Propuesta de balanceo");
    PrintToChat(client, "\x04[Balance]\x01 \x05══════════════════════");

    if (survCount > 0)
        PrintToChat(client, "\x04[Balance]\x01 \x04Survivors\x01 (avg: \x05%.0f MMR\x01) \x04↑ MMR mayor\x01:", fAvgSurv);
    else
        PrintToChat(client, "\x04[Balance]\x01 \x04Survivors\x01 \x07(equipo vacio)");

    for (int i = 0; i < survCount; i++)
    {
        char sName[MAX_NAME_LENGTH];
        GetClientName(survivors[i], sName, sizeof(sName));
        PrintToChat(client, "\x04[Balance]\x01   \x04→\x01 %s \x05(%d MMR)",
            sName, ObtenerMMR(survivors[i]));
    }

    if (infCount > 0)
        PrintToChat(client, "\x04[Balance]\x01 \x07Infected\x01 (avg: \x05%.0f MMR\x01):", fAvgInf);
    else
        PrintToChat(client, "\x04[Balance]\x01 \x07Infected\x01 \x07(equipo vacio)");

    for (int i = 0; i < infCount; i++)
    {
        char sName[MAX_NAME_LENGTH];
        GetClientName(infected[i], sName, sizeof(sName));
        PrintToChat(client, "\x04[Balance]\x01   \x07→\x01 %s \x05(%d MMR)",
            sName, ObtenerMMR(infected[i]));
    }

    PrintToChat(client, "\x04[Balance]\x01 \x05──────────────────────");

    if (survCount > 0 && infCount > 0)
    {
        PrintToChat(client, "\x04[Balance]\x01 Diferencia: \x05%.0f pts", fDiff);

        if      (fDiff <= 50.0)  PrintToChat(client, "\x04[Balance]\x01 Equilibrio: \x04Excelente ✓");
        else if (fDiff <= 150.0) PrintToChat(client, "\x04[Balance]\x01 Equilibrio: \x05Bueno");
        else                     PrintToChat(client, "\x04[Balance]\x01 Equilibrio: \x07Regular (diferencia alta)");
    }
    else
    {
        PrintToChat(client, "\x04[Balance]\x01 \x07Solo hay 1 humano. No hay balance real que aplicar.");
    }

    PrintToChat(client, "\x04[Balance]\x01 Usa \x05!balance\x01 → opción 3 para aplicar.");
}

// =============================================
// AplicarBalanceo - SIN TIMER, todo de corrido
//   PASO 1: TODOS los humanos -> Spectator
//   PASO 2: cada jugador a su equipo final inmediatamente
// =============================================
void AplicarBalanceo(int client,
                     int[] survivors, int survCount,
                     int[] infected,  int infCount)
{
    LogMessage("[Balance] ============================================");
    LogMessage("[Balance] === INICIO AplicarBalanceo ===");
    LogMessage("[Balance] Survivors a asignar: %d | Infected a asignar: %d", survCount, infCount);

    // PASO 1: Pasar TODOS a Spectator
    LogMessage("[Balance] >>> PASO 1: Pasar TODOS los humanos a Spectator");

    for (int i = 0; i < survCount; i++)
    {
        if (!IsValidHuman(survivors[i])) continue;
        int iTeamAntes = GetClientTeam(survivors[i]);
        ChangeClientTeam(survivors[i], TEAM_SPEC);
        int iTeamDespues = GetClientTeam(survivors[i]);
        LogMessage("[Balance]   %N: team %d -> Spec | resultado: team %d",
            survivors[i], iTeamAntes, iTeamDespues);
    }

    for (int i = 0; i < infCount; i++)
    {
        if (!IsValidHuman(infected[i])) continue;
        int iTeamAntes = GetClientTeam(infected[i]);
        ChangeClientTeam(infected[i], TEAM_SPEC);
        int iTeamDespues = GetClientTeam(infected[i]);
        LogMessage("[Balance]   %N: team %d -> Spec | resultado: team %d",
            infected[i], iTeamAntes, iTeamDespues);
    }

    // PASO 2: Asignar a equipos finales (inmediato, sin timer)
    LogMessage("[Balance] >>> PASO 2: Asignar a equipos finales");

    int iMovidosInf = 0;
    int iFallidosInf = 0;
    int iMovidosSurv = 0;
    int iFallidosSurv = 0;

    // INFECTED (ChangeClientTeam directo)
    for (int i = 0; i < infCount; i++)
    {
        int c = infected[i];
        if (c == 0 || !IsValidHuman(c)) continue;

        if (GetClientTeam(c) == TEAM_INFECTED)
        {
            LogMessage("[Balance]   %N ya esta en Infected", c);
            continue;
        }

        LogMessage("[Balance]   PASO 2: %N -> Infected", c);
        ChangeClientTeam(c, TEAM_INFECTED);

        int iTeamFinal = GetClientTeam(c);
        if (iTeamFinal == TEAM_INFECTED)
        {
            iMovidosInf++;
            LogMessage("[Balance]   EXITO: %N esta en Infected", c);
        }
        else
        {
            iFallidosInf++;
            LogError("[Balance]   FALLO: %N quedo en team %d", c, iTeamFinal);
        }
    }

    // SURVIVORS (TakeOverBot)
    for (int i = 0; i < survCount; i++)
    {
        int c = survivors[i];
        if (c == 0 || !IsValidHuman(c)) continue;

        if (GetClientTeam(c) == TEAM_SURVIVORS)
        {
            LogMessage("[Balance]   %N ya esta en Survivors", c);
            continue;
        }

        LogMessage("[Balance]   PASO 2: %N -> Survivors (via TakeOverBot)", c);

        if (MoverASurvivors(c))
        {
            iMovidosSurv++;
            LogMessage("[Balance]   EXITO: %N esta en Survivors", c);
        }
        else
        {
            iFallidosSurv++;
            LogError("[Balance]   FALLO al mover %N a Survivors", c);
        }
    }

    LogMessage("[Balance] === RESULTADO FINAL ===");
    LogMessage("[Balance] Infected:  %d movidos | %d fallidos", iMovidosInf, iFallidosInf);
    LogMessage("[Balance] Survivors: %d movidos | %d fallidos", iMovidosSurv, iFallidosSurv);

    if (client > 0)
    {
        int iTotalFallidos = iFallidosInf + iFallidosSurv;
        int iTotalMovidos = iMovidosInf + iMovidosSurv;

        if (iTotalFallidos > 0)
        {
            PrintToChat(client, "\x04[Balance]\x01 \x07ADVERTENCIA\x01: %d jugador(es) NO se movieron.", iTotalFallidos);
        }
        else if (iTotalMovidos > 0)
        {
            PrintToChat(client, "\x04[Balance]\x01 %d jugador(es) movido(s) exitosamente.", iTotalMovidos);
        }
    }
}

void MostrarDiferenciaActual(int client)
{
    int iSurvivors[MAX_JUGADORES];
    int iInfected[MAX_JUGADORES];
    int iSurvCount = 0;
    int iInfCount  = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsValidHuman(i))   continue;
        if (!IsClientInGame(i)) continue;
        int iTeam = GetClientTeam(i);
        if (iTeam == TEAM_SURVIVORS && iSurvCount < MAX_JUGADORES)
            iSurvivors[iSurvCount++] = i;
        else if (iTeam == TEAM_INFECTED && iInfCount < MAX_JUGADORES)
            iInfected[iInfCount++] = i;
    }

    if (iSurvCount == 0 && iInfCount == 0)
    {
        ReplyToCommand(client, "[Balance] No hay jugadores en ningún equipo.");
        return;
    }

    float fAvgSurv = PromedioMMR(iSurvivors, iSurvCount);
    float fAvgInf  = PromedioMMR(iInfected,  iInfCount);

    PrintToChat(client, "\x04[Balance]\x01 \x05══════════════════════");
    PrintToChat(client, "\x04[Balance]\x01   Estado actual de MMR");
    PrintToChat(client, "\x04[Balance]\x01 \x05══════════════════════");

    if (iSurvCount > 0)
        PrintToChat(client, "\x04[Balance]\x01 \x04Survivors\x01 (avg: \x05%.0f MMR\x01):", fAvgSurv);
    else
        PrintToChat(client, "\x04[Balance]\x01 \x04Survivors\x01 \x07(equipo vacio)");

    for (int i = 0; i < iSurvCount; i++)
    {
        char sName[MAX_NAME_LENGTH];
        GetClientName(iSurvivors[i], sName, sizeof(sName));
        PrintToChat(client, "\x04[Balance]\x01   \x04→\x01 %s \x05(%d MMR)",
            sName, ObtenerMMR(iSurvivors[i]));
    }

    if (iInfCount > 0)
        PrintToChat(client, "\x04[Balance]\x01 \x07Infected\x01 (avg: \x05%.0f MMR\x01):", fAvgInf);
    else
        PrintToChat(client, "\x04[Balance]\x01 \x07Infected\x01 \x07(equipo vacio)");

    for (int i = 0; i < iInfCount; i++)
    {
        char sName[MAX_NAME_LENGTH];
        GetClientName(iInfected[i], sName, sizeof(sName));
        PrintToChat(client, "\x04[Balance]\x01   \x07→\x01 %s \x05(%d MMR)",
            sName, ObtenerMMR(iInfected[i]));
    }

    PrintToChat(client, "\x04[Balance]\x01 \x05──────────────────────");

    if (iSurvCount > 0 && iInfCount > 0)
    {
        float fDiff = fAvgSurv - fAvgInf;
        if (fDiff < 0.0) fDiff = -fDiff;
        PrintToChat(client, "\x04[Balance]\x01 Diferencia actual: \x05%.0f pts", fDiff);

        if      (fDiff <= 50.0)  PrintToChat(client, "\x04[Balance]\x01 Equilibrio: \x04Excelente ✓ (no requiere balanceo)");
        else if (fDiff <= 150.0) PrintToChat(client, "\x04[Balance]\x01 Equilibrio: \x05Bueno");
        else                     PrintToChat(client, "\x04[Balance]\x01 Equilibrio: \x07Regular (considera balancear)");
    }
    else
    {
        PrintToChat(client, "\x04[Balance]\x01 \x07Solo hay humanos en un equipo.");
    }
}

// =============================================
// MENU PRINCIPAL
// =============================================
public Action Cmd_BalanceMenu(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[Balance] El menú solo se puede usar desde el juego.");
        return Plugin_Handled;
    }

    AbrirMenuBalance(client);
    return Plugin_Handled;
}

void AbrirMenuBalance(int client)
{
    Menu menu = new Menu(MenuHandler_Balance);
    menu.SetTitle("Balance MMR");

    menu.AddItem("auto",  "Aplicar balance auto");
    menu.AddItem("ver",   "Ver balance sugerido");

    if (g_bBalancePending)
        menu.AddItem("apply", "Aplicar balance pendiente");
    else
        menu.AddItem("apply", "Aplicar balance pendiente (no hay)", ITEMDRAW_DISABLED);

    menu.AddItem("diff",  "Ver diferencia de MMR actual");

    menu.ExitButton = true;
    menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Balance(Menu menu, MenuAction action, int client, int param2)
{
    if (action == MenuAction_End)
    {
        delete menu;
    }
    else if (action == MenuAction_Select)
    {
        char sChoice[16];
        menu.GetItem(param2, sChoice, sizeof(sChoice));

        if (StrEqual(sChoice, "auto"))
        {
            FakeClientCommand(client, "sm_balance_auto");
        }
        else if (StrEqual(sChoice, "ver"))
        {
            FakeClientCommand(client, "sm_balance_show");
        }
        else if (StrEqual(sChoice, "apply"))
        {
            FakeClientCommand(client, "sm_balance_apply");
        }
        else if (StrEqual(sChoice, "diff"))
        {
            FakeClientCommand(client, "sm_balance_diff");
        }
    }
    return 0;
}

// =============================================
// COMANDOS INDIVIDUALES
// =============================================

public Action Cmd_BalanceShow(int client, int args)
{
    if (g_DB == null)
    {
        ReplyToCommand(client, "[Balance] Error: no hay conexión con la DB del MMR.");
        return Plugin_Handled;
    }

    int iSurvivors[MAX_JUGADORES];
    int iInfected[MAX_JUGADORES];
    int iSurvCount, iInfCount;

    CalcularBalanceo(iSurvivors, iSurvCount, iInfected, iInfCount);

    if (iSurvCount == 0 && iInfCount == 0)
    {
        ReplyToCommand(client, "[Balance] No hay jugadores humanos en los equipos.");
        return Plugin_Handled;
    }

    for (int i = 0; i < iSurvCount; i++) g_BalanceSurvivors[i] = iSurvivors[i];
    for (int i = 0; i < iInfCount; i++)  g_BalanceInfected[i]  = iInfected[i];
    g_iBalanceSurvCount = iSurvCount;
    g_iBalanceInfCount  = iInfCount;
    g_bBalancePending   = true;

    MostrarPropuesta(client, iSurvivors, iSurvCount, iInfected, iInfCount);
    return Plugin_Handled;
}

public Action Cmd_BalanceApply(int client, int args)
{
    if (!g_bBalancePending)
    {
        ReplyToCommand(client, "[Balance] No hay balanceo pendiente. Usa sm_balance_show primero.");
        return Plugin_Handled;
    }

    bool bValido = true;
    for (int i = 0; i < g_iBalanceSurvCount; i++)
        if (!IsValidHuman(g_BalanceSurvivors[i])) { bValido = false; break; }
    for (int i = 0; i < g_iBalanceInfCount; i++)
        if (!IsValidHuman(g_BalanceInfected[i]))  { bValido = false; break; }

    if (!bValido)
    {
        ReplyToCommand(client, "[Balance] La propuesta expiró. Usa sm_balance_show de nuevo.");
        g_bBalancePending = false;
        return Plugin_Handled;
    }

    AplicarBalanceo(client,
                    g_BalanceSurvivors, g_iBalanceSurvCount,
                    g_BalanceInfected,  g_iBalanceInfCount);

    g_bBalancePending = false;

    PrintToChatAll("\x04[Balance]\x01 \x05══════════════════════");
    PrintToChatAll("\x04[Balance]\x01   Equipos balanceados");
    PrintToChatAll("\x04[Balance]\x01 \x05══════════════════════");

    if (g_iBalanceSurvCount > 0)
        PrintToChatAll("\x04[Balance]\x01 \x04Survivors\x01 avg: \x05%.0f MMR \x04↑ MMR mayor",
            PromedioMMR(g_BalanceSurvivors, g_iBalanceSurvCount));

    if (g_iBalanceInfCount > 0)
        PrintToChatAll("\x04[Balance]\x01 \x07Infected\x01  avg: \x05%.0f MMR",
            PromedioMMR(g_BalanceInfected, g_iBalanceInfCount));

    return Plugin_Handled;
}

public Action Cmd_BalanceAuto(int client, int args)
{
    if (g_DB == null)
    {
        ReplyToCommand(client, "[Balance] Error: no hay conexión con la DB del MMR.");
        return Plugin_Handled;
    }

    int iSurvivors[MAX_JUGADORES];
    int iInfected[MAX_JUGADORES];
    int iSurvCount, iInfCount;

    CalcularBalanceo(iSurvivors, iSurvCount, iInfected, iInfCount);

    if (iSurvCount == 0 && iInfCount == 0)
    {
        ReplyToCommand(client, "[Balance] No hay jugadores humanos en los equipos.");
        return Plugin_Handled;
    }

    AplicarBalanceo(client, iSurvivors, iSurvCount, iInfected, iInfCount);

    float fAvgSurv = PromedioMMR(iSurvivors, iSurvCount);
    float fAvgInf  = PromedioMMR(iInfected,  iInfCount);

    PrintToChatAll("\x04[Balance]\x01 \x05══════════════════════");
    PrintToChatAll("\x04[Balance]\x01   Equipos balanceados");
    PrintToChatAll("\x04[Balance]\x01 \x05══════════════════════");

    if (iSurvCount > 0)
    {
        PrintToChatAll("\x04[Balance]\x01 \x04Survivors\x01 avg: \x05%.0f MMR \x04↑ MMR mayor", fAvgSurv);
        for (int i = 0; i < iSurvCount; i++)
        {
            char sName[MAX_NAME_LENGTH];
            GetClientName(iSurvivors[i], sName, sizeof(sName));
            PrintToChatAll("\x04[Balance]\x01   \x04→\x01 %s \x05(%d MMR)",
                sName, ObtenerMMR(iSurvivors[i]));
        }
    }

    if (iInfCount > 0)
    {
        PrintToChatAll("\x04[Balance]\x01 \x07Infected\x01  avg: \x05%.0f MMR", fAvgInf);
        for (int i = 0; i < iInfCount; i++)
        {
            char sName[MAX_NAME_LENGTH];
            GetClientName(iInfected[i], sName, sizeof(sName));
            PrintToChatAll("\x04[Balance]\x01   \x07→\x01 %s \x05(%d MMR)",
                sName, ObtenerMMR(iInfected[i]));
        }
    }

    if (iSurvCount > 0 && iInfCount > 0)
    {
        float fDiff = fAvgSurv - fAvgInf;
        if (fDiff < 0.0) fDiff = -fDiff;
        PrintToChatAll("\x04[Balance]\x01 Diferencia: \x05%.0f pts", fDiff);
    }

    return Plugin_Handled;
}

public Action Cmd_BalanceDiff(int client, int args)
{
    if (g_DB == null)
    {
        ReplyToCommand(client, "[Balance] Error: no hay conexión con la DB del MMR.");
        return Plugin_Handled;
    }

    if (client == 0)
    {
        ReplyToCommand(client, "[Balance] Comando solo para uso en juego.");
        return Plugin_Handled;
    }

    MostrarDiferenciaActual(client);
    return Plugin_Handled;
}

bool IsValidHuman(int client)
{
    return (client >= 1 && client <= MaxClients
         && IsClientConnected(client)
         && IsClientInGame(client)
         && !IsFakeClient(client));
}

// =============================================
// Cmd_BalanceSimular - Para testear estando solo
// Simula el flujo completo del balance contigo:
// 1) Te mueve a Spectator
// 2) Espera 1s
// 3) Te mueve al equipo que pediste
//
// Uso: sm_balance_simular <survivor|infected|spec>
// =============================================
public Action Cmd_BalanceSimular(int client, int args)
{
    if (client == 0)
    {
        ReplyToCommand(client, "[Balance] Comando solo para uso en juego.");
        return Plugin_Handled;
    }

    if (args < 1)
    {
        ReplyToCommand(client, "[Balance] Uso: sm_balance_simular <survivor|infected|spec>");
        ReplyToCommand(client, "[Balance] Ejemplo: sm_balance_simular survivor");
        ReplyToCommand(client, "[Balance] Esto te pasa por Spectator y luego al equipo elegido,");
        ReplyToCommand(client, "[Balance] simulando el flujo del balance real.");
        return Plugin_Handled;
    }

    char sArg[16];
    GetCmdArg(1, sArg, sizeof(sArg));

    int iEquipoFinal = 0;
    if (StrEqual(sArg, "survivor", false) || StrEqual(sArg, "s", false))
        iEquipoFinal = TEAM_SURVIVORS;
    else if (StrEqual(sArg, "infected", false) || StrEqual(sArg, "i", false))
        iEquipoFinal = TEAM_INFECTED;
    else if (StrEqual(sArg, "spec", false) || StrEqual(sArg, "spectator", false))
        iEquipoFinal = TEAM_SPEC;
    else
    {
        ReplyToCommand(client, "[Balance] Equipo invalido. Usa: survivor, infected o spec");
        return Plugin_Handled;
    }

    int iTeamActual = GetClientTeam(client);
    LogMessage("[Balance-SIM] === SIMULACION ===");
    LogMessage("[Balance-SIM] %N estaba en team %d, ira a team %d", client, iTeamActual, iEquipoFinal);

    PrintToChat(client, "\x04[Balance-SIM]\x01 Simulacion iniciada.");
    PrintToChat(client, "\x04[Balance-SIM]\x01 Estabas en team \x05%d", iTeamActual);

    // PASO 1: Pasar a Spectator
    PrintToChat(client, "\x04[Balance-SIM]\x01 \x05PASO 1\x01: Pasando a Spectator...");
    LogMessage("[Balance-SIM] PASO 1: %N -> Spectator", client);
    ChangeClientTeam(client, TEAM_SPEC);

    int iTeamSpec = GetClientTeam(client);
    LogMessage("[Balance-SIM] Team despues de spec: %d", iTeamSpec);

    // Si solo querian moverse a spec, listo
    if (iEquipoFinal == TEAM_SPEC)
    {
        PrintToChat(client, "\x04[Balance-SIM]\x01 Ahora estas en Spectator.");
        return Plugin_Handled;
    }

    // PASO 2: Asignar al equipo final inmediatamente (sin timer)
    PrintToChat(client, "\x04[Balance-SIM]\x01 \x05PASO 2\x01: Asignando a equipo final...");

    if (iEquipoFinal == TEAM_INFECTED)
    {
        LogMessage("[Balance-SIM] PASO 2: %N -> Infected", client);
        ChangeClientTeam(client, TEAM_INFECTED);

        int iTeamFinal = GetClientTeam(client);
        if (iTeamFinal == TEAM_INFECTED)
        {
            PrintToChat(client, "\x04[Balance-SIM]\x01 \x04OK\x01: Estas en Infected!");
            LogMessage("[Balance-SIM] EXITO: %N esta en Infected", client);
        }
        else
        {
            PrintToChat(client, "\x04[Balance-SIM]\x01 \x07FALLO\x01: Quedaste en team %d", iTeamFinal);
            LogError("[Balance-SIM] FALLO: %N quedo en team %d", client, iTeamFinal);
        }
    }
    else if (iEquipoFinal == TEAM_SURVIVORS)
    {
        LogMessage("[Balance-SIM] PASO 2: %N -> Survivors (via TakeOverBot)", client);

        if (MoverASurvivors(client))
        {
            PrintToChat(client, "\x04[Balance-SIM]\x01 \x04OK\x01: Estas en Survivors!");
            LogMessage("[Balance-SIM] EXITO: %N esta en Survivors", client);
        }
        else
        {
            PrintToChat(client, "\x04[Balance-SIM]\x01 \x07FALLO\x01: No se pudo mover a Survivors");
            LogError("[Balance-SIM] FALLO al mover %N a Survivors", client);
        }
    }

    return Plugin_Handled;
}
