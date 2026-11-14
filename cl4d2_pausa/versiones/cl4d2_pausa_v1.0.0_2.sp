/**
 * ClubCampestre - Pausa (PRUEBA)
 *
 *   !p / !pausa / !pause -> abre una VOTACION SOLO de tu equipo (F1 = Si / F2 = No):
 *                           "KY quiere PAUSAR la partida". Pasa con mayoria de tu equipo.
 *                           (sm_pausa_votacion 0 = pausa directa sin votar)
 *   !rendirse / !gg       -> votacion SOLO de tu equipo para rendirse (75 % = 3 de 4).
 *                           Cualquier equipo, vaya ganando o perdiendo, desde el SEGUNDO capitulo.
 *                           Si votan No, ese equipo no puede volver a votar hasta el siguiente capitulo.
 *                           Al empezar cada capitulo, al equipo que va perdiendo por 500+
 *                           (sm_sr_rendirse_dif) le sale sola la votacion "¿Se rinden?".
 *                           Si se rinden: los que ganaron ven su SR; los que se rindieron eligen
 *                           campaña (20 s, cuenta al centro) y despues ven su SR.
 *                           Nadie elige -> votacion del juego para volver a la sala.
 *                           Ultimo capitulo: si un equipo ya no puede remontar ni haciendo el maximo
 *                           de puntos, le sale "¿Se rinden?" (sm_rendirse_imposible).
 *                           Si pasa, el otro equipo gana la campaña para el SR.
 *   Abajo-centro (hint): el tiempo y debajo una barra que va bajando.
 *   Izquierda: panel con los 2 equipos y una casilla por jugador.
 *   F1 (Vote Yes) o !r = listo ☑   |   F2 (Vote No) o !nr = no listo ☐
 *
 * Copiado de la pausa de ZoneMod (pause.sp):
 *   - Bloquea "unpause" de los jugadores (al reconectar o cerrar ESC despausaba).
 *   - Arregla el chat en pausa (m_fLastPlayerTalkTime).
 *   - El infectado fantasma no aparece por tener clic apretado al pausar.
 *   - Si alguien esta levantando a un companero, espera a que termine para pausar.
 *   - Si termina la ronda en pausa, se quita la pausa. No se puede pausar entre rondas.
 *   - Espectadores pueden volar durante la pausa.
 *   Cuando TODOS estan listos (o se acaba el tiempo): cuenta 3-2-1 y sigue.
 *
 * Espectador (igual que ZoneMod playermanagement):
 *   !spectate / !spec / !s -> pasar a espectador (para ir AFK)
 *   - Survivor: no se puede si te tiene agarrado un infectado (y no estas caido).
 *   - Infectado: si estas vivo (no fantasma) te mueres al pasar; el Tank no puede.
 *   Para volver: tecla M o "jointeam 2" / "jointeam 3" en consola.
 *   sm_spec_tanque 0 -> 1 = survivors no pueden ir a espectador con Tank en juego
 *   sm_cambios_ilimitados 1 -> cambiar de equipo cuantas veces quieran
 *                              (pone vs_max_team_switches en 9999; el juego trae 1)
 *   NOTA: si tienes playermanagement.smx de ZoneMod, quita uno de los dos.
 *
 * Ayuda:
 *   !ayuda / !comandos -> vuelve a abrir el MOTD (motd.txt) con los comandos
 *
 * Admin:
 *   sm_forzarpausa       -> pausa sin gastar pausas de equipo
 *   sm_forzarreanudar    -> reanuda ya (cuenta 3-2-1)
 *
 * Cvars:
 *   sm_pausa_tiempo   120  -> segundos maximos de pausa
 *   sm_pausa_max      3    -> pausas por equipo por mapa (0 = sin limite)
 *   sm_pausa_cuenta   3    -> segundos de cuenta atras antes de reanudar
 *   sm_pausa_sonido_cuenta  -> beep de cada segundo de la cuenta (weapons/hegrenade/beep.wav)
 *   sm_pausa_sonido_vuelta  -> sonido al reanudar (ui/survival_medal.wav)
 *   sm_pausa_simbolos 1    -> 1 = casillas ☑ ☐   |   0 = [X] [  ]
 *   sm_pausa_estilo   3    -> 3 = SIN barra, solo el tiempo | 0 = ||||....  1 = ██████▒▒▒▒  2 = ■■■■□□□□
 *   sm_tiempo_lugar   1    -> donde salen TODOS los tiempos: 1 = centro | 2 = abajo al medio | 0 = pausa en el panel
 *   (se pueden cambiar en cualquier momento desde la consola)
 *   sm_pausa_testbarra     -> muestra la barra SIN pausar (para ver que estilo/lugar se ve)
 *
 * Votaciones:
 *   sm_pausa_votacion 1    -> 1 = !p pide votacion | 0 = pausa directa
 *   sm_voto_tiempo    15   -> segundos de cada votacion
 *   sm_voto_espera    30   -> si tu votacion fallo, esperas esto para abrir otra
 *   sm_rendirse       1    -> permite !rendirse
 *   sm_rendirse_pct   75   -> % del equipo que debe votar Si (con 1 o 2 jugadores: todos)
 *
 * NOTA: no usar junto con el pause.sp de ZoneMod (se pisan).
 */
#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define TEAM_SPEC       1
#define TEAM_SURVIVORS  2
#define TEAM_INFECTED   3

#define BARRA_LARGO     20
#define NOMBRE_MAX      16

public Plugin myinfo =
{
    name        = "ClubCampestre Pausa (prueba)",
    author      = "ClubCampestre",
    description = "Pausa por equipo con barra de tiempo y casillas de listo (F1)",
    version     = "1.0.0",
    url         = ""
};

ConVar g_cvTiempo;
ConVar g_cvMax;
ConVar g_cvCuenta;
ConVar g_cvSimbolos;
ConVar g_cvBarra;
ConVar g_cvLugar;
ConVar g_cvSonCuenta;   // beep de cada segundo de "REANUDANDO EN 3..."
ConVar g_cvSonVuelta;   // sonido cuando la partida vuelve a empezar
char   g_sTiempoTxt[16];               // "1:23" o "REANUDANDO EN 3..."
char   g_sBarraTxt[128];               // la barra
int    g_iTestSeg = 0;                 // prueba de barra
Handle g_hTest = null;
ConVar g_cvPausable;

bool   g_bPausado   = false;
int    g_iRestante  = 0;      // segundos de pausa que quedan
int    g_iTotal     = 0;      // segundos totales de esta pausa
int    g_iCuenta    = 0;      // > 0 = reanudando (cuenta atras)
int    g_iTeamPauso = 0;
char   g_sQuienPauso[MAX_NAME_LENGTH];
bool   g_bListo[MAXPLAYERS + 1];
int    g_iPausasUsadas[4];
Handle g_hTimer = null;
bool   g_bComandoInterno = false;  // true solo mientras ESTE plugin pausa/despausa
bool   g_bFinRonda = false;        // entre round_end y round_start no se puede pausar
Handle g_hEsperarRevive = null;    // pausa diferida mientras alguien levanta a un companero
int    g_iTeamPendiente = 0;
ConVar g_cvNoclipPausa;            // sv_noclipduringpause (espectadores vuelan en la pausa)
ConVar g_cvSpecTanque;             // bloquear spec de survivors con Tank en juego
ConVar g_cvCambiosIlimitados;      // nuestro cvar: 1 = cambios de equipo ilimitados
ConVar g_cvMaxCambios;             // vs_max_team_switches del juego (por defecto 1)
float  g_fUltimoSpec[MAXPLAYERS + 1];   // anti-abuso: pausar justo despues de ir a spec

// =========================================================================
// VOTACIONES (misma ventana del juego que "cambiar de campaña": F1 = Si, F2 = No)
//
//   !p / !pausa       -> votacion SOLO de tu equipo: "KY quiere PAUSAR la partida"
//                        Pasa con mayoria del equipo (mas de la mitad; solo = pasa al toque), o al acabar el tiempo si hay mas Si que No.
//   !rendirse / !gg   -> votacion SOLO de tu equipo: "KY quiere RENDIRSE"
//                        Pasa si votan Si al menos sm_rendirse_pct % del equipo (3 de 4).
//                        El otro equipo gana la campaña para el SR (resultado normal, sin castigo).
//
//   Se usa la ventana de votacion del juego: mensaje VoteStart / VotePass / VoteFail,
//   el contador del vote_controller y los eventos vote_changed / vote_cast_yes / vote_cast_no.
// =========================================================================

#define VOTO_NINGUNO   0
#define VOTO_PAUSA     1
#define VOTO_RENDIRSE  2

int    g_iVotoTipo      = VOTO_NINGUNO;
int    g_iVotoEquipo    = 0;              // 0 = vota todo el que juega | 2/3 = solo ese equipo
int    g_iVotoIniciador = 0;              // userid del que la inicio
char   g_sVotoNombre[MAX_NAME_LENGTH];
int    g_iVotoMio[MAXPLAYERS + 1];        // 0 = no voto, 1 = si, 2 = no
bool   g_bVotoPuede[MAXPLAYERS + 1];      // puede votar (se fija al empezar)
int    g_iVotoSeg       = 0;
Handle g_hVotoTimer     = null;
float  g_fVotoEspera[MAXPLAYERS + 1];     // anti-spam: hasta cuando no puede iniciar otra

ConVar g_cvVotoPausa;
ConVar g_cvVotoTiempo;
ConVar g_cvVotoEsperaSeg;
ConVar g_cvRendirse;
ConVar g_cvRendirsePct;
ConVar g_cvRendirseAuto;
ConVar g_cvRendirseImposible;
ConVar g_cvElegirCampania;
ConVar g_cvCampaniaTiempo;
int    g_iRondasMapa      = 0;        // round_start de este mapa (1 = primera mitad)
int    g_iAutoIntentos    = 0;
int    g_iMapaVoto[MAXPLAYERS + 1];   // campaña elegida por cada uno (-1 = ninguna)
bool   g_bMenuCampania    = false;
int    g_iCampEquipo      = 0;        // lado que se rindio (el que elige campaña)
int    g_iCampSeg         = 0;        // segundos que quedan (elegir / cambiar de mapa / volver a la sala)
int    g_iCampElegida     = 0;
bool   g_bRendirseUsado[4];           // ese lado ya voto rendirse (y fallo) en este capitulo

// Natives opcionales del plugin del SR (cl4d2_sr)
native int  CL4D2_SR_PuedeRendirse(int iLado, int &iDiferencia);   // 0 = si | 1 = primer capitulo | 3 = campaña terminada
native bool CL4D2_SR_Rendirse(int iLado);
native bool CL4D2_SR_PanelRendicionPrueba(int iLado);
native bool CL4D2_SR_MostrarPanelFin(int client);
native bool CL4D2_SR_RemontadaImposible(int iLado);
native int  L4D_RestartScenarioFromVote(const char[] map);   // left4dhooks (opcional): cambia de campaña como la votacion del juego

bool   g_bVotoPrueba       = false;   // la votacion actual es de prueba (sm_test_rendirse)
bool   g_bCampaniaPrueba   = false;   // el menu de campañas es de prueba
bool   g_bPruebaCambiaMapa = false;   // sm_test_rendirse cambiar -> si cambia de mapa al final

void Votos_OnPluginStart()
{
    g_cvVotoPausa     = CreateConVar("sm_pausa_votacion", "1",  "1 = !p abre una votacion para pausar | 0 = pausa directa", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvVotoTiempo    = CreateConVar("sm_voto_tiempo",    "15", "Segundos que dura cada votacion", FCVAR_NOTIFY, true, 5.0, true, 60.0);
    g_cvVotoEsperaSeg = CreateConVar("sm_voto_espera",    "30", "Segundos que debe esperar un jugador para iniciar otra votacion si la suya fallo", FCVAR_NOTIFY, true, 0.0, true, 600.0);
    g_cvRendirse      = CreateConVar("sm_rendirse",       "1",  "1 = permite !rendirse / !gg", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRendirsePct   = CreateConVar("sm_rendirse_pct",   "75", "Porcentaje del equipo que debe votar Si para rendirse (75 = 3 de 4)", FCVAR_NOTIFY, true, 50.0, true, 100.0);
    g_cvRendirseAuto  = CreateConVar("sm_rendirse_auto",  "1",  "1 = al empezar cada capitulo, al equipo que pierde por sm_sr_rendirse_dif (500) le sale la votacion de rendirse", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvRendirseImposible = CreateConVar("sm_rendirse_imposible", "1", "1 = en el ultimo capitulo, si un equipo ya no puede remontar, le sale la votacion de rendirse", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvElegirCampania = CreateConVar("sm_rendirse_campania", "1", "1 = si se rinden, todos eligen una campaña nueva", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCampaniaTiempo = CreateConVar("sm_campania_voto_tiempo", "20", "Segundos que tiene el equipo que se rindio para elegir la campaña nueva", FCVAR_NOTIFY, true, 5.0, true, 60.0);

    RegConsoleCmd("sm_rendirse",  Cmd_Rendirse, "Votacion de tu equipo para rendirse");
    RegConsoleCmd("sm_ayuda",     Cmd_Ayuda,    "Muestra los comandos del servidor");
    RegConsoleCmd("sm_comandos",  Cmd_Ayuda,    "Muestra los comandos del servidor");

    RegConsoleCmd("sm_rendir",    Cmd_Rendirse, "Votacion de tu equipo para rendirse");
    RegConsoleCmd("sm_gg",        Cmd_Rendirse, "Votacion de tu equipo para rendirse");
    RegConsoleCmd("sm_surrender", Cmd_Rendirse, "Votacion de tu equipo para rendirse");
    RegAdminCmd("sm_test_rendirse", Cmd_TestRendirse, ADMFLAG_GENERIC,
        "PRUEBA de rendicion: votacion -> panel -> menu de campañas. No toca el SR. 'sm_test_rendirse cambiar' = si cambia de mapa al final");

    // Mientras hay una votacion nuestra, no dejar abrir una del juego (se pisan)
    AddCommandListener(Listener_CallVote, "callvote");
}

void Votos_OnMapStart()
{
    g_iVotoTipo  = VOTO_NINGUNO;
    g_hVotoTimer = null;     // TIMER_FLAG_NO_MAPCHANGE lo borra
    g_iRondasMapa   = 0;
    g_iAutoIntentos = 0;
    g_bMenuCampania = false;
    for (int t = 0; t < 4; t++) g_bRendirseUsado[t] = false;   // capitulo nuevo: se puede volver a votar
}

void Votos_OnClientDisconnect(int client)
{
    g_iVotoMio[client]    = 0;
    g_bVotoPuede[client]  = false;
    g_fVotoEspera[client] = 0.0;
}

bool HayVotoNuestro()
{
    return g_iVotoTipo != VOTO_NINGUNO;
}

// ¿Hay una votacion del juego en curso (cambiar campaña, kick, etc.)?
bool HayVotoDelJuego()
{
    int ent = FindEntityByClassname(-1, "vote_controller");
    if (ent == -1 || !HasEntProp(ent, Prop_Send, "m_activeIssueIndex")) return false;
    return GetEntProp(ent, Prop_Send, "m_activeIssueIndex") != -1;
}

public Action Listener_CallVote(int client, const char[] command, int argc)
{
    if (!HayVotoNuestro()) return Plugin_Continue;
    if (client > 0 && IsClientInGame(client)) PrintHintText(client, "Espera a que termine la votacion actual.");
    return Plugin_Handled;
}

// ─── Iniciar ───

bool PuedeIniciarVoto(int client)
{
    if (HayVotoNuestro() || HayVotoDelJuego())
    {
        PrintHintText(client, "Ya hay una votacion en curso.");
        return false;
    }
    float fFalta = g_fVotoEspera[client] - GetEngineTime();
    if (fFalta > 0.0)
    {
        PrintHintText(client, "Espera %d s para iniciar otra votacion.", RoundToCeil(fFalta));
        return false;
    }
    return true;
}

// iEquipo: 0 = votan todos los que juegan | 2/3 = solo ese equipo
// client = 0 -> la inicia el servidor (votacion automatica); sTextoServidor = lo que se muestra
void IniciarVoto(int client, int iTipo, int iEquipo, const char[] sTextoServidor = "")
{
    g_iVotoTipo      = iTipo;
    g_iVotoEquipo    = iEquipo;
    if (client > 0)
    {
        g_iVotoIniciador = GetClientUserId(client);
        GetClientName(client, g_sVotoNombre, sizeof(g_sVotoNombre));
    }
    else
    {
        g_iVotoIniciador = 0;
        strcopy(g_sVotoNombre, sizeof(g_sVotoNombre), "ClubCampestre");
    }
    g_iVotoSeg       = g_cvVotoTiempo.IntValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_iVotoMio[i]   = 0;
        g_bVotoPuede[i] = PuedeVotar(i);
    }

    char sTexto[128];
    if (sTextoServidor[0] != '\0') strcopy(sTexto, sizeof(sTexto), sTextoServidor);
    else if (iTipo == VOTO_PAUSA) Format(sTexto, sizeof(sTexto), "%s quiere PAUSAR la partida", g_sVotoNombre);
    else                     Format(sTexto, sizeof(sTexto), "%s quiere que tu equipo se RINDA", g_sVotoNombre);

    // Ventana de votacion del juego (solo a los que pueden votar)
    int iClientes[MAXPLAYERS], n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (g_bVotoPuede[i]) iClientes[n++] = i;

    if (n > 0)
    {
        Handle hMsg = StartMessage("VoteStart", iClientes, n, USERMSG_RELIABLE);
        if (hMsg != null)
        {
            BfWriteByte(hMsg, iEquipo > 0 ? iEquipo : 255);   // equipo que vota (255 = todos)
            BfWriteByte(hMsg, client > 0 ? client : 99);       // quien la inicio (99 = servidor)
            BfWriteString(hMsg, "#L4D_TargetID_Player");       // "%s1" -> muestra nuestro texto
            BfWriteString(hMsg, sTexto);
            BfWriteString(hMsg, g_sVotoNombre);
            EndMessage();
        }
    }

    ControladorVoto(true);
    LogMessage("[Voto] %s inicio votacion: %s", g_sVotoNombre, iTipo == VOTO_PAUSA ? "PAUSA" : "RENDIRSE");

    // El que la inicia vota Si (si es una votacion automatica, nadie vota por adelantado)
    if (client > 0) RegistrarVoto(client, true);

    if (g_iVotoTipo != VOTO_NINGUNO)
        MostrarTiempoVoto();
    if (g_iVotoTipo != VOTO_NINGUNO && g_hVotoTimer == null)
        g_hVotoTimer = CreateTimer(1.0, Timer_Voto, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

bool PuedeVotar(int client)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return false;
    int t = GetClientTeam(client);
    if (t != TEAM_SURVIVORS && t != TEAM_INFECTED) return false;
    if (g_iVotoEquipo > 0 && t != g_iVotoEquipo) return false;
    return true;
}

// ─── Contar ───

void ContarVotos(int &iSi, int &iNo, int &iPosibles)
{
    iSi = 0; iNo = 0; iPosibles = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!g_bVotoPuede[i]) continue;
        if (!IsClientInGame(i)) { g_bVotoPuede[i] = false; continue; }   // se fue
        iPosibles++;
        if (g_iVotoMio[i] == 1) iSi++;
        else if (g_iVotoMio[i] == 2) iNo++;
    }
}

int VotosNecesarios(int iPosibles)
{
    if (iPosibles <= 0) return 1;
    if (g_iVotoTipo == VOTO_RENDIRSE)
    {
        if (iPosibles <= 2) return iPosibles;   // 1v1 o 2 jugadores: todos
        int iNec = RoundToCeil(float(iPosibles) * g_cvRendirsePct.FloatValue / 100.0);
        return (iNec < 1) ? 1 : iNec;
    }
    return iPosibles / 2 + 1;                    // pausa: mayoria
}

void RegistrarVoto(int client, bool bSi)
{
    if (!g_bVotoPuede[client] || g_iVotoMio[client] != 0) return;   // ya voto
    g_iVotoMio[client] = bSi ? 1 : 2;

    Event ev = CreateEvent(bSi ? "vote_cast_yes" : "vote_cast_no", true);
    if (ev != null)
    {
        ev.SetInt("team", GetClientTeam(client));
        ev.SetInt("entityid", client);
        ev.Fire();
    }
    ControladorVoto(true);
    ComprobarFinVoto(false);
}

// Actualiza el contador de la ventana (si / no / posibles)
void ControladorVoto(bool bActivo)
{
    int iSi, iNo, iPos;
    ContarVotos(iSi, iNo, iPos);

    int ent = FindEntityByClassname(-1, "vote_controller");
    if (ent != -1)
    {
        if (HasEntProp(ent, Prop_Send, "m_activeIssueIndex")) SetEntProp(ent, Prop_Send, "m_activeIssueIndex", bActivo ? 0 : -1);
        if (HasEntProp(ent, Prop_Send, "m_onlyTeamToVote"))   SetEntProp(ent, Prop_Send, "m_onlyTeamToVote", (bActivo && g_iVotoEquipo > 0) ? g_iVotoEquipo : -1);
        if (HasEntProp(ent, Prop_Send, "m_votesYes"))         SetEntProp(ent, Prop_Send, "m_votesYes", bActivo ? iSi : 0);
        if (HasEntProp(ent, Prop_Send, "m_votesNo"))          SetEntProp(ent, Prop_Send, "m_votesNo", bActivo ? iNo : 0);
        if (HasEntProp(ent, Prop_Send, "m_potentialVotes"))   SetEntProp(ent, Prop_Send, "m_potentialVotes", bActivo ? iPos : 0);
    }

    if (!bActivo) return;
    Event ev = CreateEvent("vote_changed", true);
    if (ev != null)
    {
        ev.SetInt("yesVotes", iSi);
        ev.SetInt("noVotes", iNo);
        ev.SetInt("potentialVotes", iPos);
        ev.Fire();
    }
}

public Action Timer_Voto(Handle timer)
{
    if (g_iVotoTipo == VOTO_NINGUNO) { g_hVotoTimer = null; return Plugin_Stop; }
    g_iVotoSeg--;
    ControladorVoto(true);
    MostrarTiempoVoto();
    if (ComprobarFinVoto(g_iVotoSeg <= 0) || g_iVotoTipo == VOTO_NINGUNO)
    {
        g_hVotoTimer = null;
        return Plugin_Stop;
    }
    return Plugin_Continue;
}

// Devuelve true si la votacion termino
bool ComprobarFinVoto(bool bSeAcaboElTiempo)
{
    if (g_iVotoTipo == VOTO_NINGUNO) return true;

    int iSi, iNo, iPos;
    ContarVotos(iSi, iNo, iPos);
    int iNec = VotosNecesarios(iPos);

    if (iPos == 0)                          { TerminarVoto(false); return true; }
    if (iSi >= iNec)                        { TerminarVoto(true);  return true; }
    if (iSi + (iPos - iSi - iNo) < iNec && g_iVotoTipo == VOTO_RENDIRSE)
                                            { TerminarVoto(false); return true; }   // ya no llega
    if (g_iVotoTipo == VOTO_PAUSA && iNo >= iNec)
                                            { TerminarVoto(false); return true; }   // mayoria dijo No
    if (iSi + iNo >= iPos)
    {
        // Ya votaron todos
        TerminarVoto(g_iVotoTipo == VOTO_PAUSA ? (iSi > iNo) : (iSi >= iNec));
        return true;
    }
    if (bSeAcaboElTiempo)
    {
        // Pausa: gana el Si si hay mas Si que No. Rendirse: necesita el % pedido.
        TerminarVoto(g_iVotoTipo == VOTO_PAUSA ? (iSi > iNo) : (iSi >= iNec));
        return true;
    }
    return false;
}

// ─── Terminar ───

void TerminarVoto(bool bPasa)
{
    int iTipo   = g_iVotoTipo;
    int iEquipo = g_iVotoEquipo;
    int client  = GetClientOfUserId(g_iVotoIniciador);

    // Ventana: aprobado / rechazado (a los que podian votar)
    int iClientes[MAXPLAYERS], n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (g_bVotoPuede[i] && IsClientInGame(i)) iClientes[n++] = i;

    if (n > 0)
    {
        Handle hMsg;
        if (bPasa)
        {
            hMsg = StartMessage("VotePass", iClientes, n, USERMSG_RELIABLE);
            if (hMsg != null)
            {
                BfWriteByte(hMsg, iEquipo > 0 ? iEquipo : 255);
                BfWriteString(hMsg, "#L4D_TargetID_Player");
                BfWriteString(hMsg, iTipo == VOTO_PAUSA ? "Pausa aprobada" : "Rendicion aprobada");
                EndMessage();
            }
        }
        else
        {
            hMsg = StartMessage("VoteFail", iClientes, n, USERMSG_RELIABLE);
            if (hMsg != null)
            {
                BfWriteByte(hMsg, iEquipo > 0 ? iEquipo : 255);
                EndMessage();
            }
        }
    }

    g_iVotoTipo = VOTO_NINGUNO;
    ControladorVoto(false);
    for (int i = 1; i <= MaxClients; i++) { g_iVotoMio[i] = 0; g_bVotoPuede[i] = false; }

    LogMessage("[Voto] %s: %s", iTipo == VOTO_PAUSA ? "PAUSA" : "RENDIRSE", bPasa ? "APROBADA" : "RECHAZADA");

    if (!bPasa)
    {
        if (g_bVotoPrueba)
        {
            g_bVotoPrueba = false;
            PrintToChatAll("\x04[PRUEBA]\x01 Rendicion rechazada (no paso nada).");
            return;
        }
        if (iTipo == VOTO_RENDIRSE)
        {
            // Si dijeron que no, no pueden volver a votar rendirse hasta el siguiente capitulo
            if (iEquipo == TEAM_SURVIVORS || iEquipo == TEAM_INFECTED) g_bRendirseUsado[iEquipo] = true;
            return;
        }
        if (client > 0) g_fVotoEspera[client] = GetEngineTime() + g_cvVotoEsperaSeg.FloatValue;
        return;
    }

    if (iTipo == VOTO_PAUSA)
    {
        // El equipo del que la pidio gasta 1 pausa
        int t = (client > 0 && IsClientInGame(client)) ? GetClientTeam(client) : 0;
        if (t == TEAM_SURVIVORS || t == TEAM_INFECTED) g_iPausasUsadas[t]++;
        strcopy(g_sQuienPauso, sizeof(g_sQuienPauso), g_sVotoNombre);
        if (!g_bPausado && g_hEsperarRevive == null && !g_bFinRonda)
            IntentarPausa((t == TEAM_SURVIVORS || t == TEAM_INFECTED) ? t : 0);
    }
    else if (iTipo == VOTO_RENDIRSE && g_bVotoPrueba)
    {
        g_bVotoPrueba = false;
        // Panel de resultados (inventado) a los que ganaron; los que se rinden lo ven despues de elegir
        if (GetFeatureStatus(FeatureType_Native, "CL4D2_SR_PanelRendicionPrueba") == FeatureStatus_Available)
            CL4D2_SR_PanelRendicionPrueba(iEquipo);
        PrintToChatAll("\x04[PRUEBA]\x01 El SR NO se modifico.");
        g_bCampaniaPrueba = true;
        DespuesDeRendirse(iEquipo);
    }
    else if (iTipo == VOTO_RENDIRSE)
    {
        bool bOk = false;
        if (GetFeatureStatus(FeatureType_Native, "CL4D2_SR_Rendirse") == FeatureStatus_Available)
            bOk = CL4D2_SR_Rendirse(iEquipo);
        if (!bOk)
            PrintHintTextToAll("Rendicion aprobada, pero no cuenta para el SR.");
        else
            DespuesDeRendirse(iEquipo);
        LogMessage("[Voto] Rendicion del equipo %s: %s", iEquipo == TEAM_SURVIVORS ? "survivors" : "infectados",
            bOk ? "procesada en el SR" : "NO procesada en el SR");
    }
}

// Cancela sin resultado (por ejemplo, si un admin pausa en medio de una votacion de pausa)
void CancelarVoto()
{
    if (g_iVotoTipo == VOTO_NINGUNO) return;
    g_bVotoPrueba = false;
    int iClientes[MAXPLAYERS], n = 0;
    for (int i = 1; i <= MaxClients; i++)
        if (g_bVotoPuede[i] && IsClientInGame(i)) iClientes[n++] = i;
    if (n > 0)
    {
        Handle hMsg = StartMessage("VoteFail", iClientes, n, USERMSG_RELIABLE);
        if (hMsg != null)
        {
            BfWriteByte(hMsg, g_iVotoEquipo > 0 ? g_iVotoEquipo : 255);
            EndMessage();
        }
    }
    g_iVotoTipo = VOTO_NINGUNO;
    ControladorVoto(false);
    for (int i = 1; i <= MaxClients; i++) { g_iVotoMio[i] = 0; g_bVotoPuede[i] = false; }
}

// ─── !rendirse ───

public Action Cmd_Rendirse(int client, int args)
{
    if (client == 0 || !IsClientInGame(client)) return Plugin_Handled;
    if (!g_cvRendirse.BoolValue) return Plugin_Handled;
    if (g_bPausado || g_bMenuCampania) return Plugin_Handled;   // en pausa simplemente no funciona

    int t = GetClientTeam(client);
    if (t != TEAM_SURVIVORS && t != TEAM_INFECTED)
    {
        PrintHintText(client, "Solo survivors o infectados pueden rendirse.");
        return Plugin_Handled;
    }
    if (GetFeatureStatus(FeatureType_Native, "CL4D2_SR_PuedeRendirse") != FeatureStatus_Available)
    {
        PrintHintText(client, "Rendirse no esta disponible (falta el plugin del SR).");
        return Plugin_Handled;
    }
    int iDif = 0;
    int iMotivo = CL4D2_SR_PuedeRendirse(t, iDif);
    if (iMotivo == 3)
    {
        PrintHintText(client, "La campaña ya termino.");
        return Plugin_Handled;
    }
    if (iMotivo != 0)
    {
        PrintHintText(client, "Solo se pueden rendir a partir del segundo capitulo.");
        return Plugin_Handled;
    }
    if (g_bRendirseUsado[t])
    {
        PrintHintText(client, "Tu equipo ya voto rendirse en este capitulo. Pueden intentarlo en el siguiente.");
        return Plugin_Handled;
    }
    if (HayVotoNuestro() || HayVotoDelJuego())
    {
        PrintHintText(client, "Ya hay una votacion en curso.");
        return Plugin_Handled;
    }

    IniciarVoto(client, VOTO_RENDIRSE, t);
    return Plugin_Handled;
}


// Permite que otros plugins (el del SR) sepan si estamos en pausa
public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    CreateNative("CL4D2_EstaEnPausa", Native_EstaEnPausa);
    RegPluginLibrary("cl4d2_pausa");
    MarkNativeAsOptional("CL4D2_SR_PuedeRendirse");
    MarkNativeAsOptional("CL4D2_SR_Rendirse");
    MarkNativeAsOptional("CL4D2_SR_PanelRendicionPrueba");
    MarkNativeAsOptional("CL4D2_SR_MostrarPanelFin");
    MarkNativeAsOptional("CL4D2_SR_RemontadaImposible");
    MarkNativeAsOptional("L4D_RestartScenarioFromVote");
    return APLRes_Success;
}

public int Native_EstaEnPausa(Handle plugin, int numParams)
{
    return g_bPausado ? 1 : 0;
}

public void OnPluginStart()
{
    g_cvTiempo = CreateConVar("sm_pausa_tiempo", "120", "Segundos maximos de la pausa", FCVAR_NOTIFY, true, 10.0, true, 600.0);
    g_cvMax    = CreateConVar("sm_pausa_max",    "3",   "Pausas por equipo por mapa (0 = sin limite)", FCVAR_NOTIFY, true, 0.0);
    g_cvCuenta = CreateConVar("sm_pausa_cuenta", "3",   "Segundos de cuenta atras antes de reanudar", FCVAR_NOTIFY, true, 1.0, true, 10.0);
    g_cvSimbolos = CreateConVar("sm_pausa_simbolos", "1", "1 = casillas ☑ ☐ | 0 = [X] [  ]", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvBarra    = CreateConVar("sm_pausa_estilo", "3", "Barra de la pausa: 3 = SIN barra, solo el tiempo | 0 = ||||.... | 1 = ██████▒▒▒▒ | 2 = ■■■■□□□□", FCVAR_NOTIFY, true, 0.0, true, 3.0);
    g_cvLugar    = CreateConVar("sm_tiempo_lugar", "1", "Donde salen TODOS los tiempos de los plugins (pausa, votaciones, elegir campaña, cambio de mapa): 1 = centro | 2 = abajo al medio (en L4D2 no se ve si cambia cada segundo) | 0 = pausa dentro del panel izquierdo", FCVAR_NOTIFY, true, 0.0, true, 2.0);
    g_cvSonCuenta = CreateConVar("sm_pausa_sonido_cuenta", "weapons/hegrenade/beep.wav", "Sonido de cada segundo de la cuenta atras (vacio = sin sonido)", FCVAR_NOTIFY);
    g_cvSonVuelta = CreateConVar("sm_pausa_sonido_vuelta", "ui/survival_medal.wav",      "Sonido cuando se reanuda la partida (vacio = sin sonido)", FCVAR_NOTIFY);
    g_cvSpecTanque = CreateConVar("sm_spec_tanque", "0", "1 = survivors no pueden ir a espectador con un Tank en juego", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvCambiosIlimitados = CreateConVar("sm_cambios_ilimitados", "1", "1 = cambiar de equipo cuantas veces quieran (vs_max_team_switches 9999)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    Votos_OnPluginStart();
    AutoExecConfig(true, "cl4d2_pausa");

    // El juego limita los cambios de equipo con vs_max_team_switches (por defecto 1).
    g_cvMaxCambios = FindConVar("vs_max_team_switches");
    if (g_cvMaxCambios != null) g_cvMaxCambios.AddChangeHook(OnMaxCambiosCambio);
    g_cvCambiosIlimitados.AddChangeHook(OnMaxCambiosCambio);

    g_cvPausable    = FindConVar("sv_pausable");
    g_cvNoclipPausa = FindConVar("sv_noclipduringpause");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
    HookEvent("round_end",   Event_RoundEnd,   EventHookMode_PostNoCopy);
    HookEvent("player_say",  Event_PlayerSay,  EventHookMode_Post);

    RegConsoleCmd("sm_pausa", Cmd_Pausa, "Pausa la partida (tu equipo)");
    RegConsoleCmd("sm_pause", Cmd_Pausa, "Pausa la partida (tu equipo)");
    RegConsoleCmd("sm_p",     Cmd_Pausa, "Pausa la partida (tu equipo)");
    // Alternativa a F1/F2 por chat (por si alguien tiene F1/F2 cambiados)
    RegConsoleCmd("sm_r",      Cmd_Listo,   "Pausa: marcarte como listo");
    RegConsoleCmd("sm_listo",  Cmd_Listo,   "Pausa: marcarte como listo");
    RegConsoleCmd("sm_ready",  Cmd_Listo,   "Pausa: marcarte como listo");
    RegConsoleCmd("sm_nr",     Cmd_NoListo, "Pausa: marcarte como NO listo");
    RegConsoleCmd("sm_unready",Cmd_NoListo, "Pausa: marcarte como NO listo");
    RegConsoleCmd("sm_spectate", Cmd_Spec, "Pasar a espectador");
    RegConsoleCmd("sm_spec",     Cmd_Spec, "Pasar a espectador");
    RegConsoleCmd("sm_s",        Cmd_Spec, "Pasar a espectador");
    RegAdminCmd("sm_pausa_testbarra", Cmd_TestBarra, ADMFLAG_GENERIC, "Muestra la barra sin pausar (prueba)");
    RegAdminCmd("sm_forzarpausa",    Cmd_ForzarPausa,    ADMFLAG_GENERIC, "Pausa la partida (admin)");
    RegAdminCmd("sm_forzarreanudar", Cmd_ForzarReanudar, ADMFLAG_GENERIC, "Reanuda la partida (admin)");

    // F1 = "Vote Yes", F2 = "Vote No"
    AddCommandListener(Listener_Vote, "Vote");

    // Bloquear que los jugadores quiten la pausa por su cuenta.
    // OJO: el juego del cliente manda "unpause" SOLO al terminar de cargar
    // (alguien que se reconecta) o al cerrar el menu con ESC. Eso despausaba.
    AddCommandListener(Listener_BloquearPausa, "unpause");
    AddCommandListener(Listener_BloquearPausa, "pause");
    AddCommandListener(Listener_BloquearPausa, "setpause");
}

#define SONIDO_BEEP    "buttons/blip1.wav"   // F1 (listo)
#define SONIDO_BEEP_NO "buttons/blip2.wav"   // F2 (no listo)


public void OnMapStart()
{
    PrecacheSound(SONIDO_BEEP, true);
    PrecacheSound(SONIDO_BEEP_NO, true);
    g_hTest = null;
    g_bPausado = false;
    g_iCuenta  = 0;
    g_hTimer   = null;      // TIMER_FLAG_NO_MAPCHANGE lo borra
    g_hEsperarRevive = null;
    g_bFinRonda = false;
    for (int t = 0; t < 4; t++) g_iPausasUsadas[t] = 0;
    Votos_OnMapStart();
}

public void OnClientDisconnect(int client)
{
    g_bListo[client] = false;
    g_fUltimoSpec[client] = 0.0;
    Votos_OnClientDisconnect(client);
}

// Alguien termino de cargar durante la pausa (ej: el que se reconecto)
public void OnClientPutInServer(int client)
{
    if (!g_bPausado || IsFakeClient(client)) return;
    ArreglarChat(client);
}

// ─── Fin / inicio de ronda (igual que ZoneMod) ───

public void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    g_bFinRonda = false;

    // Primera mitad de un capitulo: ¿algun equipo va perdiendo por 500 o mas?
    g_iRondasMapa++;
    // Mitad 1: regla de los 500 puntos. Mitad 1 y 2 del ultimo capitulo: "ya no puede remontar".
    if (g_cvRendirseAuto.BoolValue || g_cvRendirseImposible.BoolValue)
    {
        g_iAutoIntentos = 0;
        CreateTimer(15.0, Timer_AutoRendirse, _, TIMER_FLAG_NO_MAPCHANGE);   // esperar a que carguen
    }
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
    g_bFinRonda = true;
    if (g_hEsperarRevive != null) { KillTimer(g_hEsperarRevive); g_hEsperarRevive = null; }
    if (g_bPausado)
    {
        // Si termina la ronda en pausa, se libera sin cuenta atras
        EjecutarPausa("unpause");
        TerminarPausa();
    }
}

// ─── Chat durante la pausa ───
// En pausa el tiempo del juego no avanza y el anti-flood del chat bloquea los mensajes.
// ZoneMod lo arregla reseteando m_fLastPlayerTalkTime; hacemos lo mismo.

void ArreglarChat(int client)
{
    if (IsClientInGame(client))
        SetEntPropFloat(client, Prop_Data, "m_fLastPlayerTalkTime", 0.0);
}

public void Event_PlayerSay(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bPausado) return;
    RequestFrame(Frame_ArreglarChat, event.GetInt("userid"));
}

public void Frame_ArreglarChat(int userid)
{
    int client = GetClientOfUserId(userid);
    if (client > 0 && g_bPausado) ArreglarChat(client);
}

// ─── Pausar / reanudar el juego ───

int ClienteCualquiera()
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i)) return i;
    return 0;
}

bool EjecutarPausa(const char[] sCmd)
{
    int c = ClienteCualquiera();
    if (c == 0 || g_cvPausable == null) return false;
    g_bComandoInterno = true;
    g_cvPausable.SetInt(1);
    FakeClientCommand(c, sCmd);       // "setpause" o "unpause"
    g_cvPausable.SetInt(0);
    g_bComandoInterno = false;
    return true;
}

public Action Listener_BloquearPausa(int client, const char[] command, int argc)
{
    if (g_bComandoInterno) return Plugin_Continue;   // lo mandamos nosotros
    if (g_bPausado)        return Plugin_Handled;    // durante NUESTRA pausa nadie la toca
    return Plugin_Continue;
}

// Red de seguridad: si por cualquier motivo el juego se despauso solo
// (IsServerProcessing = true significa que el juego esta corriendo), se vuelve a pausar.
void ComprobarSigueEnPausa()
{
    if (!g_bPausado) return;
    if (IsServerProcessing())
    {
        LogMessage("[Pausa] El juego se despauso solo: se vuelve a pausar.");
        EjecutarPausa("setpause");
    }
}

// ─── Comandos ───

public Action Cmd_Pausa(int client, int args)
{
    if (client == 0) { ReplyToCommand(client, "[Pausa] Usalo dentro del juego."); return Plugin_Handled; }
    if (g_bPausado || g_hEsperarRevive != null) { return Plugin_Handled; }
    if (g_bFinRonda)
    {
        PrintHintText(client, "No se puede pausar entre rondas.");
        return Plugin_Handled;
    }

    int t = GetClientTeam(client);
    if (t != TEAM_SURVIVORS && t != TEAM_INFECTED)
    {
        PrintHintText(client, "Solo survivors o infectados pueden pausar.");
        return Plugin_Handled;
    }
    if (GetEngineTime() - g_fUltimoSpec[client] < 7.0)
    {
        PrintHintText(client, "Espera unos segundos despues de cambiar de equipo.");
        return Plugin_Handled;
    }

    int iMax = g_cvMax.IntValue;
    if (iMax > 0 && g_iPausasUsadas[t] >= iMax)
    {
        PrintHintText(client, "Tu equipo ya uso sus %d pausas en este mapa.", iMax);
        return Plugin_Handled;
    }

    if (g_cvVotoPausa.BoolValue)
    {
        // Votacion: "KY quiere PAUSAR la partida" (la pausa se gasta solo si se aprueba)
        if (!PuedeIniciarVoto(client)) return Plugin_Handled;
        IniciarVoto(client, VOTO_PAUSA, t);   // vota solo su equipo
        return Plugin_Handled;
    }

    g_iPausasUsadas[t]++;
    GetClientName(client, g_sQuienPauso, sizeof(g_sQuienPauso));
    IntentarPausa(t);
    return Plugin_Handled;
}

// Como ZoneMod: si un survivor esta levantando a otro, se espera a que termine
// (pausar en medio de un levantamiento lo bugea).
void IntentarPausa(int iTeam)
{
    if (!AlguienLevantando()) { IniciarPausa(iTeam); return; }
    g_iTeamPendiente = iTeam;
    PrintHintTextToAll("Pausa en cuanto termine el levantamiento...");
    g_hEsperarRevive = CreateTimer(0.1, Timer_EsperarRevive, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_EsperarRevive(Handle timer)
{
    if (AlguienLevantando()) return Plugin_Continue;
    g_hEsperarRevive = null;
    IniciarPausa(g_iTeamPendiente);
    return Plugin_Stop;
}

bool AlguienLevantando()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || GetClientTeam(i) != TEAM_SURVIVORS || !IsPlayerAlive(i)) continue;
        if (GetEntProp(i, Prop_Send, "m_reviveTarget") > 0) return true;
    }
    return false;
}

public Action Cmd_ForzarPausa(int client, int args)
{
    if (g_bPausado) { ReplyToCommand(client, "[Pausa] Ya esta en pausa."); return Plugin_Handled; }
    strcopy(g_sQuienPauso, sizeof(g_sQuienPauso), "Admin");
    IniciarPausa(0);   // el admin pausa al instante
    return Plugin_Handled;
}

public Action Cmd_ForzarReanudar(int client, int args)
{
    if (!g_bPausado) { ReplyToCommand(client, "[Pausa] No esta en pausa."); return Plugin_Handled; }
    if (g_iCuenta == 0)
    {
        g_iCuenta = g_cvCuenta.IntValue;
        SonidoATodos(g_cvSonCuenta);
    }
    return Plugin_Handled;
}

void IniciarPausa(int iTeam)
{
    CancelarVoto();   // si habia una votacion abierta (ej: un admin forzo la pausa)
    if (!EjecutarPausa("setpause")) return;

    g_bPausado   = true;
    g_iTeamPauso = iTeam;
    g_iTotal     = g_cvTiempo.IntValue;
    g_iRestante  = g_iTotal;
    g_iCuenta    = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        g_bListo[i] = false;
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;

        ArreglarChat(i);

        int t = GetClientTeam(i);
        // Como ZoneMod: que el infectado fantasma no aparezca por haber tenido clic apretado
        if (t == TEAM_INFECTED && GetEntProp(i, Prop_Send, "m_isGhost") == 1)
        {
            SetEntProp(i, Prop_Send, "m_hasVisibleThreats", 1);
            int iBotones = GetClientButtons(i);
            if (iBotones & IN_ATTACK)
                SetEntProp(i, Prop_Data, "m_nButtons", iBotones & ~IN_ATTACK);
        }
        // Espectadores pueden volar durante la pausa
        if (t == TEAM_SPEC && g_cvNoclipPausa != null)
            g_cvNoclipPausa.ReplicateToClient(i, "1");
    }

    Dibujar();
    if (g_hTimer != null) KillTimer(g_hTimer);
    g_hTimer = CreateTimer(1.0, Timer_Pausa, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// ─── F1 / F2 ───

public Action Listener_Vote(int client, const char[] command, int argc)
{
    // Votacion nuestra en curso (pausa / rendirse)
    if (HayVotoNuestro())
    {
        if (client == 0 || !IsClientInGame(client)) return Plugin_Handled;
        char sVoto[8];
        GetCmdArg(1, sVoto, sizeof(sVoto));
        if      (StrEqual(sVoto, "Yes", false)) RegistrarVoto(client, true);
        else if (StrEqual(sVoto, "No",  false)) RegistrarVoto(client, false);
        return Plugin_Handled;
    }

    if (!g_bPausado || client == 0 || !IsClientInGame(client)) return Plugin_Continue;

    int t = GetClientTeam(client);
    if (t != TEAM_SURVIVORS && t != TEAM_INFECTED) return Plugin_Handled;

    char sArg[8];
    GetCmdArg(1, sArg, sizeof(sArg));
    if      (StrEqual(sArg, "Yes", false)) MarcarListo(client, true);
    else if (StrEqual(sArg, "No",  false)) MarcarListo(client, false);
    return Plugin_Handled;   // durante la pausa no hay votaciones del juego
}

void MarcarListo(int client, bool bListo)
{
    g_bListo[client] = bListo;
    Beep(client, bListo);
    // si se desmarca durante la cuenta atras, se cancela
    if (!bListo && g_iCuenta > 0 && g_iRestante > 0) g_iCuenta = 0;
    Dibujar();
}

public Action Cmd_Listo(int client, int args)   { return CmdListoComun(client, true);  }
public Action Cmd_NoListo(int client, int args) { return CmdListoComun(client, false); }

Action CmdListoComun(int client, bool bListo)
{
    if (!g_bPausado || client == 0 || !IsClientInGame(client)) return Plugin_Continue;
    int t = GetClientTeam(client);
    if (t != TEAM_SURVIVORS && t != TEAM_INFECTED) return Plugin_Handled;
    MarcarListo(client, bListo);
    return Plugin_Handled;
}

// Deja todo como antes de la pausa (el "unpause" ya se mando antes de llamar esto)
void TerminarPausa()
{
    g_bPausado = false;
    g_iCuenta  = 0;
    if (g_hTimer != null) { KillTimer(g_hTimer); g_hTimer = null; }
    CerrarPaneles();
    if (g_cvNoclipPausa != null)
    {
        for (int i = 1; i <= MaxClients; i++)
            if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SPEC)
                g_cvNoclipPausa.ReplicateToClient(i, "0");
    }
}

// ─── Bucle de la pausa (cada 1 seg) ───

public Action Timer_Pausa(Handle timer)
{
    if (!g_bPausado) { g_hTimer = null; return Plugin_Stop; }

    ComprobarSigueEnPausa();

    if (g_iCuenta > 0)
    {
        g_iCuenta--;
        if (g_iCuenta == 0)
        {
            SonidoATodos(g_cvSonVuelta);          // ya empezo
            EjecutarPausa("unpause");
            g_hTimer = null;                      // este timer termina solo
            TerminarPausa();
            TiempoATodos("¡A JUGAR!");
            return Plugin_Stop;
        }
        SonidoATodos(g_cvSonCuenta);              // 2... 1...
        Dibujar();
        return Plugin_Continue;
    }

    if (g_iRestante > 0) g_iRestante--;

    if (TodosListos() || g_iRestante <= 0)
    {
        g_iCuenta = g_cvCuenta.IntValue;
        SonidoATodos(g_cvSonCuenta);              // 3...
    }

    Dibujar();
    return Plugin_Continue;
}

bool TodosListos()
{
    int n = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        int t = GetClientTeam(i);
        if (t != TEAM_SURVIVORS && t != TEAM_INFECTED) continue;
        if (!g_bListo[i]) return false;
        n++;
    }
    return n > 0;
}

// ─── Dibujo: barra al centro + panel a la izquierda ───

void Dibujar()
{
    if (g_iCuenta > 0)
    {
        Format(g_sTiempoTxt, sizeof(g_sTiempoTxt), "REANUDANDO EN %d...", g_iCuenta);
        ArmarBarra(g_sBarraTxt, sizeof(g_sBarraTxt), 0, 1);
    }
    else
    {
        Format(g_sTiempoTxt, sizeof(g_sTiempoTxt), "%d:%02d", g_iRestante / 60, g_iRestante % 60);
        ArmarBarra(g_sBarraTxt, sizeof(g_sBarraTxt), g_iRestante, g_iTotal);
    }
    MostrarBarraFuera();

    // Panel izquierdo (igual para todos)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        Panel panel = ArmarPanel();
        panel.Send(i, PanelHandler_Nada, 2);
        delete panel;
    }
}

Panel ArmarPanel()
{
    Panel panel = new Panel();
    char sLinea[96];

    panel.DrawText("ClubCampestre :: PAUSA");
    panel.DrawText("___________________________");
    if (g_cvLugar.IntValue == 0)
    {
        panel.DrawText(g_sTiempoTxt);
        if (g_sBarraTxt[0] != '\0') panel.DrawText(g_sBarraTxt);
        panel.DrawText(" ");
    }
    Format(sLinea, sizeof(sLinea), "Pauso: %s%s", g_sQuienPauso,
        g_iTeamPauso == TEAM_SURVIVORS ? " (Survivors)" : (g_iTeamPauso == TEAM_INFECTED ? " (Infectados)" : ""));
    panel.DrawText(sLinea);
    panel.DrawText(" ");

    AgregarEquipo(panel, TEAM_SURVIVORS, "SURVIVORS");
    panel.DrawText(" ");
    AgregarEquipo(panel, TEAM_INFECTED, "INFECTADOS");

    panel.DrawText(" ");
    panel.DrawText("F1 = listo   |   F2 = no listo");
    return panel;
}

void AgregarEquipo(Panel panel, int iTeam, const char[] sTitulo)
{
    int iTotal = 0, iListos = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != iTeam) continue;
        iTotal++;
        if (g_bListo[i]) iListos++;
    }

    char sLinea[96];
    Format(sLinea, sizeof(sLinea), "%s   %d/%d", sTitulo, iListos, iTotal);
    panel.DrawItem(sLinea);   // naranja

    if (iTotal == 0) { panel.DrawText("    (sin jugadores)"); return; }

    char sNombre[MAX_NAME_LENGTH], sNom[MAX_NAME_LENGTH];
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != iTeam) continue;
        GetClientName(i, sNombre, sizeof(sNombre));
        RecortarNombre(sNombre, sNom, sizeof(sNom), NOMBRE_MAX);
        if (g_cvSimbolos.BoolValue)
            Format(sLinea, sizeof(sLinea), "    %s  %s", g_bListo[i] ? "☑" : "☐", sNom);
        else
            Format(sLinea, sizeof(sLinea), "    %s  %s", g_bListo[i] ? "[X]" : "[  ]", sNom);
        panel.DrawText(sLinea);
    }
}

void CerrarPaneles()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        Panel panel = new Panel();
        panel.DrawText(" ");
        panel.Send(i, PanelHandler_Nada, 1);
        delete panel;
    }
}

public int PanelHandler_Nada(Menu menu, MenuAction action, int param1, int param2)
{
    return 0;
}

void RecortarNombre(const char[] sNombre, char[] sOut, int iLen, int iMax)
{
    int iChars = 0, i = 0;
    while (sNombre[i] != '\0')
    {
        if ((sNombre[i] & 0xC0) != 0x80)
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

// Solo la barra (el tiempo va en g_sTiempoTxt)
void ArmarBarra(char[] sOut, int iLen, int iRestante, int iTotal)
{
    if (g_cvBarra.IntValue == 3) { sOut[0] = '\0'; return; }   // sin barra
    int iLlenos = (iTotal > 0) ? RoundToCeil(float(BARRA_LARGO) * float(iRestante) / float(iTotal)) : 0;

    char sLleno[8], sVacio[8];
    switch (g_cvBarra.IntValue)
    {
        case 1:  { strcopy(sLleno, sizeof(sLleno), "█"); strcopy(sVacio, sizeof(sVacio), "▒"); }
        case 2:  { strcopy(sLleno, sizeof(sLleno), "■"); strcopy(sVacio, sizeof(sVacio), "□"); }
        default: { strcopy(sLleno, sizeof(sLleno), "|"); strcopy(sVacio, sizeof(sVacio), "."); }
    }

    char sB[BARRA_LARGO * 4 + 4];
    sB[0] = '\0';
    for (int k = 0; k < BARRA_LARGO; k++)
        StrCat(sB, sizeof(sB), (k < iLlenos) ? sLleno : sVacio);

    strcopy(sOut, iLen, sB);
}

// Sonidito al apretar F1 (agudo) o F2 (grave). "play" suena aunque el juego este en pausa.
void Beep(int client, bool bListo)
{
    if (!IsClientInGame(client) || IsFakeClient(client)) return;
    ClientCommand(client, "play %s", bListo ? SONIDO_BEEP : SONIDO_BEEP_NO);
}

// Si la barra va al centro o abajo (lugar 1 o 2), mostrarla ahi en UNA linea
void MostrarBarraFuera()
{
    char sTxt[192];
    if (g_sBarraTxt[0] == '\0')
    {
        // Sin barra: solo el tiempo ("PAUSA  1:23" o "REANUDANDO EN 3...")
        if (g_iCuenta > 0 || StrContains(g_sTiempoTxt, "REANUDANDO") == 0) strcopy(sTxt, sizeof(sTxt), g_sTiempoTxt);
        else Format(sTxt, sizeof(sTxt), "PAUSA  %s", g_sTiempoTxt);
    }
    else Format(sTxt, sizeof(sTxt), "%s   %s", g_sTiempoTxt, g_sBarraTxt);
    if (g_cvLugar.IntValue != 0) TiempoATodos(sTxt);
}

// Prueba de la barra sin pausar: 10 seg bajando, en el lugar elegido

public Action Cmd_TestBarra(int client, int args)
{
    g_iTestSeg = 10;
    MostrarTest();
    if (g_hTest == null)
        g_hTest = CreateTimer(1.0, Timer_TestBarra, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
    ReplyToCommand(client, "[Pausa] Probando estilo %d en lugar %d (sm_pausa_estilo 0/1/2/3 | sm_tiempo_lugar 0/1/2).",
        g_cvBarra.IntValue, g_cvLugar.IntValue);
    return Plugin_Handled;
}

public Action Timer_TestBarra(Handle timer)
{
    g_iTestSeg--;
    if (g_iTestSeg < 0 || g_bPausado) { g_hTest = null; return Plugin_Stop; }
    MostrarTest();
    return Plugin_Continue;
}

void MostrarTest()
{
    Format(g_sTiempoTxt, sizeof(g_sTiempoTxt), "%d:%02d", g_iTestSeg / 60, g_iTestSeg % 60);
    ArmarBarra(g_sBarraTxt, sizeof(g_sBarraTxt), g_iTestSeg, 10);

    if (g_cvLugar.IntValue != 0) { MostrarBarraFuera(); return; }

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        Panel panel = new Panel();
        panel.DrawText("ClubCampestre :: PRUEBA BARRA");
        panel.DrawText("___________________________");
        panel.DrawText(g_sTiempoTxt);
        panel.DrawText(g_sBarraTxt);
        panel.Send(i, PanelHandler_Nada, 2);
        delete panel;
    }
}

// Reproduce el sonido del cvar a todos ("play" suena aunque el juego este en pausa)
void SonidoATodos(ConVar cv)
{
    char sSonido[PLATFORM_MAX_PATH];
    cv.GetString(sSonido, sizeof(sSonido));
    if (sSonido[0] == '\0') return;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i))
            ClientCommand(i, "play %s", sSonido);
}

// ─── Espectador (copiado de ZoneMod playermanagement.sp) ───

#define ZC_CHARGER  6
#define ZC_TANK     8

public Action Cmd_Spec(int client, int args)
{
    if (client == 0 || !IsClientInGame(client)) return Plugin_Handled;

    int t = GetClientTeam(client);
    if (t == TEAM_SPEC)
    {
        PrintHintText(client, "Ya eres espectador. Para volver: tecla M o jointeam 2 / 3");
        return Plugin_Handled;
    }

    if (t == TEAM_SURVIVORS)
    {
        if (g_cvSpecTanque.BoolValue && HayTanque())
        {
            PrintHintText(client, "No puedes ir a espectador con un Tank en juego.");
            return Plugin_Handled;
        }
        if (EstaAgarrado(client) && !EstaCaido(client))
        {
            PrintHintText(client, "No puedes ir a espectador mientras te agarra un infectado.");
            return Plugin_Handled;
        }
    }
    else if (t == TEAM_INFECTED)
    {
        int zc = GetEntProp(client, Prop_Send, "m_zombieClass");
        if (zc == ZC_TANK)
        {
            PrintHintText(client, "El Tank no puede ir a espectador.");
            return Plugin_Handled;
        }
        // Vivo (no fantasma) y no cargando con el Charger -> se muere al pasar (como ZoneMod)
        if (IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_isGhost") == 0 && !ChargerCargando(client))
            ForcePlayerSuicide(client);
    }

    ChangeClientTeam(client, TEAM_SPEC);
    g_fUltimoSpec[client] = GetEngineTime();
    g_bListo[client] = false;

    char sNombre[MAX_NAME_LENGTH];
    GetClientName(client, sNombre, sizeof(sNombre));
    PrintToChatAll("\x04[ClubCampestre]\x01 %s paso a espectador.", sNombre);

    if (g_bPausado)
    {
        if (g_cvNoclipPausa != null) g_cvNoclipPausa.ReplicateToClient(client, "1");
        Dibujar();
    }
    return Plugin_Handled;
}

bool EstaAgarrado(int client)
{
    static const char sProps[][] = { "m_pounceAttacker", "m_tongueOwner", "m_pummelAttacker", "m_carryAttacker", "m_jockeyAttacker" };
    for (int k = 0; k < sizeof(sProps); k++)
    {
        if (GetEntPropEnt(client, Prop_Send, sProps[k]) > 0) return true;
    }
    return false;
}

bool EstaCaido(int client)
{
    return GetEntProp(client, Prop_Send, "m_isIncapacitated") != 0;
}

bool ChargerCargando(int client)
{
    if (!IsPlayerAlive(client) || GetEntProp(client, Prop_Send, "m_zombieClass") != ZC_CHARGER) return false;
    int ability = GetEntPropEnt(client, Prop_Send, "m_customAbility");
    if (ability > 0 && IsValidEntity(ability) && GetEntProp(ability, Prop_Send, "m_isCharging")) return true;
    return GetEntPropEnt(client, Prop_Send, "m_carryVictim") > 0 || (GetEntityFlags(client) & FL_FROZEN);
}

bool HayTanque()
{
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && GetClientTeam(i) == TEAM_INFECTED && IsPlayerAlive(i)
            && GetEntProp(i, Prop_Send, "m_zombieClass") == ZC_TANK)
            return true;
    }
    return false;
}

// ─── Cambios de equipo ilimitados ───

public void OnConfigsExecuted()
{
    AplicarCambiosIlimitados();   // despues de que se cargan los cfg (por si alguno lo pone en 1)
}

public void OnMaxCambiosCambio(ConVar convar, const char[] oldValue, const char[] newValue)
{
    AplicarCambiosIlimitados();
}

void AplicarCambiosIlimitados()
{
    if (g_cvMaxCambios == null || !g_cvCambiosIlimitados.BoolValue) return;
    if (g_cvMaxCambios.IntValue < 9999) g_cvMaxCambios.SetInt(9999);
}

// =========================================================================
// RENDIRSE AUTOMATICO + ELEGIR CAMPAÑA NUEVA
// =========================================================================

// Al empezar un capitulo: si un equipo va perdiendo por sm_sr_rendirse_dif (500) o mas,
// a ese equipo le sale la votacion "Van perdiendo por X puntos. ¿Se rinden?"
public Action Timer_AutoRendirse(Handle timer)
{
    if (!g_cvRendirse.BoolValue) return Plugin_Stop;
    if (GetFeatureStatus(FeatureType_Native, "CL4D2_SR_PuedeRendirse") != FeatureStatus_Available) return Plugin_Stop;

    // Si hay pausa u otra votacion, reintentar (hasta 1 minuto)
    if (g_bPausado || HayVotoNuestro() || HayVotoDelJuego() || g_bMenuCampania)
    {
        if (++g_iAutoIntentos <= 12) CreateTimer(5.0, Timer_AutoRendirse, _, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Stop;
    }

    for (int iLado = TEAM_SURVIVORS; iLado <= TEAM_INFECTED; iLado++)
    {
        int iDif = 0;
        if (CL4D2_SR_PuedeRendirse(iLado, iDif) != 0) continue;
        if (g_bRendirseUsado[iLado]) continue;
        if (!EquipoTieneHumanos(iLado)) continue;

        char sTexto[128];

        // 1) Ultimo capitulo: ya no puede remontar -> solo "¿Se rinden?"
        if (g_cvRendirseImposible.BoolValue
            && GetFeatureStatus(FeatureType_Native, "CL4D2_SR_RemontadaImposible") == FeatureStatus_Available
            && CL4D2_SR_RemontadaImposible(iLado))
        {
            strcopy(sTexto, sizeof(sTexto), "¿Se rinden?");
            LogMessage("[Voto] Votacion automatica de rendirse para %s: ya no pueden remontar.",
                iLado == TEAM_SURVIVORS ? "survivors" : "infectados");
            IniciarVoto(0, VOTO_RENDIRSE, iLado, sTexto);
            break;
        }

        // 2) Inicio de capitulo (mitad 1): van perdiendo por 500 o mas
        if (!g_cvRendirseAuto.BoolValue || EnSegundaMitad()) continue;   // solo en la 1ra ronda del capitulo
        ConVar cvDif = FindConVar("sm_sr_rendirse_dif");
        int iMin = (cvDif != null) ? cvDif.IntValue : 500;
        if (iDif < iMin || iMin <= 0) continue;          // solo si van perdiendo por 500 o mas

        Format(sTexto, sizeof(sTexto), "Van perdiendo por %d puntos. ¿Se rinden?", iDif);
        LogMessage("[Voto] Votacion automatica de rendirse para %s (pierden por %d).",
            iLado == TEAM_SURVIVORS ? "survivors" : "infectados", iDif);
        IniciarVoto(0, VOTO_RENDIRSE, iLado, sTexto);
        break;   // solo un equipo puede ir perdiendo
    }
    return Plugin_Stop;
}

// La 2da ronda del capitulo (cuando se cambian los lados). Lo dice el propio juego.
bool EnSegundaMitad()
{
    return GameRules_GetProp("m_bInSecondHalfOfRound") != 0;
}

bool EquipoTieneHumanos(int iLado)
{
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == iLado) return true;
    return false;
}

// ─── Despues de rendirse: el equipo que se rindio elige campaña ───
//   - Los que ganaron: ven su panel de SR al instante (lo muestra el plugin del SR).
//   - Los que se rindieron: menu de campañas + cuenta atras al centro (20, 19, 18...).
//     Al terminar ven su panel de SR (lo que perdieron).
//   - Gana la campaña mas votada (empate: al azar). Si nadie elige: votacion del juego
//     para volver a la sala.

static const char g_sCampNombre[][] = {
    "Punto muerto (Dead Center)", "Feria siniestra (Dark Carnival)", "Fiebre del pantano (Swamp Fever)",
    "Diluvio (Hard Rain)", "La parroquia (The Parish)", "El paso (The Passing)",
    "El sacrificio (The Sacrifice)", "Sin piedad (No Mercy)", "Curso de choque (Crash Course)",
    "Peaje de muerte (Death Toll)", "Aire muerto (Dead Air)", "Cosecha de sangre (Blood Harvest)",
    "Corriente fria (Cold Stream)", "La ultima resistencia (The Last Stand)"
};
static const char g_sCampMapa[][] = {
    "c1m1_hotel", "c2m1_highway", "c3m1_plankcountry", "c4m1_milltown_a", "c5m1_waterfront",
    "c6m1_riverbank", "c7m1_docks", "c8m1_apartment", "c9m1_alleys", "c10m1_caves",
    "c11m1_greenhouse", "c12m1_hilltop", "c13m1_alpinecreek", "c14m1_junkyard"
};

void DespuesDeRendirse(int iLado)
{
    if (!g_cvElegirCampania.BoolValue)
    {
        MostrarPanelPerdedores(iLado);
        return;
    }

    g_bMenuCampania = true;
    g_iCampEquipo   = iLado;
    g_iCampSeg      = g_cvCampaniaTiempo.IntValue;

    for (int i = 1; i <= MaxClients; i++)
    {
        g_iMapaVoto[i] = -1;
        if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != iLado) continue;

        PrintToChat(i, "Rendicion aprobada. Elijan la campaña nueva en el menu.");

        Menu menu = new Menu(MenuHandler_Campania);
        menu.SetTitle("Elige la campaña nueva");
        char sIdx[4];
        for (int c = 0; c < sizeof(g_sCampMapa); c++)
        {
            if (!IsMapValid(g_sCampMapa[c])) continue;
            IntToString(c, sIdx, sizeof(sIdx));
            menu.AddItem(sIdx, g_sCampNombre[c]);
        }
        menu.Display(i, g_iCampSeg + 1);
        char sT[64];
        Format(sT, sizeof(sT), "Elige la campaña nueva: %d", g_iCampSeg);
        TiempoA(i, sT);
    }
    CreateTimer(1.0, Timer_CuentaCampania, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public int MenuHandler_Campania(Menu menu, MenuAction action, int param1, int param2)
{
    if (action == MenuAction_Select)
    {
        char sIdx[4];
        menu.GetItem(param2, sIdx, sizeof(sIdx));
        int c = StringToInt(sIdx);
        if (c >= 0 && c < sizeof(g_sCampMapa))
        {
            g_iMapaVoto[param1] = c;
            PrintHintText(param1, "Votaste por: %s", g_sCampNombre[c]);
        }
    }
    else if (action == MenuAction_End)
    {
        delete menu;
    }
    return 0;
}

// Cuenta atras al centro: 20, 19, 18...
public Action Timer_CuentaCampania(Handle timer)
{
    if (!g_bMenuCampania) return Plugin_Stop;
    g_iCampSeg--;
    if (g_iCampSeg > 0)
    {
        for (int i = 1; i <= MaxClients; i++)
            if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == g_iCampEquipo)
            {
                char sT[64];
                Format(sT, sizeof(sT), "Elige la campaña nueva: %d", g_iCampSeg);
                TiempoA(i, sT);
            }
        return Plugin_Continue;
    }
    ResultadoCampania();
    return Plugin_Stop;
}

void ResultadoCampania()
{
    g_bMenuCampania = false;

    int iVotos[sizeof(g_sCampMapa)];
    int iMax = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || IsFakeClient(i)) continue;
        if (GetClientTeam(i) == g_iCampEquipo) CancelClientMenu(i);
        int c = g_iMapaVoto[i];
        g_iMapaVoto[i] = -1;
        if (c < 0 || c >= sizeof(g_sCampMapa)) continue;
        iVotos[c]++;
        if (iVotos[c] > iMax) iMax = iVotos[c];
    }

    // Ahora los que se rindieron ven lo que perdieron
    MostrarPanelPerdedores(g_iCampEquipo);

    bool bPrueba = g_bCampaniaPrueba;
    g_bCampaniaPrueba = false;

    if (iMax == 0)
    {
        if (bPrueba && !g_bPruebaCambiaMapa)
        {
            PrintToChatAll("\x04[PRUEBA]\x01 Nadie eligio campaña. (En una partida real se abriria la votacion para volver a la sala.)");
            return;
        }
        PrintToChatAll("Nadie eligio campaña. Votacion para volver a la sala...");
        LogMessage("[Voto] Nadie eligio campaña: votacion para volver a la sala.");
        g_iCampSeg = 10;
        char sT[96];
        Format(sT, sizeof(sT), "Votacion para volver a la sala en %d", g_iCampSeg);
        TiempoATodos(sT);
        CreateTimer(1.0, Timer_VolverSala, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
        return;
    }

    int iEmpatadas[sizeof(g_sCampMapa)], n = 0;
    for (int c = 0; c < sizeof(g_sCampMapa); c++)
        if (iVotos[c] == iMax) iEmpatadas[n++] = c;
    int iElegida = iEmpatadas[GetRandomInt(0, n - 1)];

    LogMessage("[Voto] Campaña elegida: %s (%s), %d votos%s.", g_sCampNombre[iElegida], g_sCampMapa[iElegida], iMax,
        bPrueba ? " [PRUEBA]" : "");

    if (bPrueba && !g_bPruebaCambiaMapa)
    {
        PrintToChatAll("\x04[PRUEBA]\x01 Gano: %s (%d votos). No se cambia de mapa.", g_sCampNombre[iElegida], iMax);
        return;
    }

    PrintToChatAll("Siguiente campaña: %s", g_sCampNombre[iElegida]);
    g_iCampElegida = iElegida;
    g_iCampSeg     = 10;            // tiempo para ver el panel
    char sT[128];
    Format(sT, sizeof(sT), "Siguiente campaña: %s en %d", g_sCampNombre[iElegida], g_iCampSeg);
    TiempoATodos(sT);
    CreateTimer(1.0, Timer_CuentaCambio, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// Cuenta al centro: "Siguiente campaña: X en 10, 9, 8..." y cambia
public Action Timer_CuentaCambio(Handle timer)
{
    g_iCampSeg--;
    if (g_iCampSeg > 0)
    {
        char sT[128];
        Format(sT, sizeof(sT), "Siguiente campaña: %s en %d", g_sCampNombre[g_iCampElegida], g_iCampSeg);
        TiempoATodos(sT);
        return Plugin_Continue;
    }
    CambiarMapa(g_sCampMapa[g_iCampElegida]);
    return Plugin_Stop;
}

void MostrarPanelPerdedores(int iLado)
{
    if (GetFeatureStatus(FeatureType_Native, "CL4D2_SR_MostrarPanelFin") != FeatureStatus_Available) return;
    for (int i = 1; i <= MaxClients; i++)
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == iLado)
            CL4D2_SR_MostrarPanelFin(i);
}

void CambiarMapa(const char[] sMapa)
{
    if (!IsMapValid(sMapa)) return;
    // Igual que la votacion "cambiar de campaña" del juego (si hay left4dhooks); si no, changelevel
    if (GetFeatureStatus(FeatureType_Native, "L4D_RestartScenarioFromVote") == FeatureStatus_Available)
        L4D_RestartScenarioFromVote(sMapa);
    else
        ServerCommand("changelevel %s", sMapa);
}

// Nadie eligio: se abre la votacion del juego "Volver a la sala"
public Action Timer_VolverSala(Handle timer)
{
    g_iCampSeg--;
    if (g_iCampSeg > 0)
    {
        char sT[96];
        Format(sT, sizeof(sT), "Votacion para volver a la sala en %d", g_iCampSeg);
        TiempoATodos(sT);
        return Plugin_Continue;
    }
    int c = ClienteCualquiera();
    if (c > 0) FakeClientCommand(c, "callvote ReturnToLobby");
    return Plugin_Stop;
}

// ─── PRUEBA: sm_test_rendirse [cambiar] ───
// Abre la votacion de rendirse para TU equipo (sin la regla de los 500 puntos ni de las mitades).
// Si votas F1: panel de rendicion con numeros inventados -> menu de campañas.
// No modifica el SR. Sin "cambiar", al final solo anuncia la campaña elegida.
public Action Cmd_TestRendirse(int client, int args)
{
    if (client == 0 || !IsClientInGame(client)) { ReplyToCommand(client, "[PRUEBA] Usalo dentro del juego."); return Plugin_Handled; }
    int t = GetClientTeam(client);
    if (t != TEAM_SURVIVORS && t != TEAM_INFECTED)
    {
        ReplyToCommand(client, "[PRUEBA] Tienes que estar en survivors o infectados.");
        return Plugin_Handled;
    }
    if (g_bPausado) { ReplyToCommand(client, "[PRUEBA] No durante la pausa."); return Plugin_Handled; }
    if (HayVotoNuestro() || HayVotoDelJuego() || g_bMenuCampania)
    {
        ReplyToCommand(client, "[PRUEBA] Ya hay una votacion o menu en curso.");
        return Plugin_Handled;
    }

    char sArg[16];
    if (args >= 1) GetCmdArg(1, sArg, sizeof(sArg));
    g_bPruebaCambiaMapa = StrEqual(sArg, "cambiar", false);

    g_bVotoPrueba = true;
    IniciarVoto(0, VOTO_RENDIRSE, t, "[PRUEBA] Van perdiendo. ¿Se rinden?");
    ReplyToCommand(client, "[PRUEBA] Votacion abierta para tu equipo: aprieta F1 (Si) o F2 (No).%s",
        g_bPruebaCambiaMapa ? " Al final SI cambia de mapa." : " Al final NO cambia de mapa.");
    return Plugin_Handled;
}

// ─── !ayuda / !comandos: vuelve a abrir el MOTD (motd.txt) ───
public Action Cmd_Ayuda(int client, int args)
{
    if (client == 0 || !IsClientInGame(client) || IsFakeClient(client)) return Plugin_Handled;
    // L4D2 no muestra paginas web en el MOTD: se abre el motd.txt del servidor (texto)
    ShowMOTDPanel(client, "ClubCampestre", "motd", MOTDPANEL_TYPE_INDEX);
    return Plugin_Handled;
}

// ─── Donde salen los tiempos (sm_tiempo_lugar) ───
// 1 = centro (PrintCenterText) | 2 = abajo al medio (PrintHintText)
// (0 = la pausa va dentro del panel; los demas tiempos van al centro)
void TiempoATodos(const char[] sTexto)
{
    if (g_cvLugar.IntValue == 2) PrintHintTextToAll("%s", sTexto);
    else                         PrintCenterTextAll("%s", sTexto);
}

void TiempoA(int client, const char[] sTexto)
{
    if (g_cvLugar.IntValue == 2) PrintHintText(client, "%s", sTexto);
    else                         PrintCenterText(client, "%s", sTexto);
}

// Tiempo de la votacion (abajo al medio, o donde diga sm_tiempo_lugar) a los que pueden votar:
// "Rendirse: 12 s" / "Pausar: 12 s"
void MostrarTiempoVoto()
{
    if (g_iVotoTipo == VOTO_NINGUNO || g_iVotoSeg <= 0) return;
    char sT[48];
    Format(sT, sizeof(sT), "%s: %d s", g_iVotoTipo == VOTO_PAUSA ? "Pausar" : "Rendirse", g_iVotoSeg);
    for (int i = 1; i <= MaxClients; i++)
        if (g_bVotoPuede[i] && IsClientInGame(i)) TiempoA(i, sT);
}
