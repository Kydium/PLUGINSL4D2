#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>

#define PLUGIN_VERSION "2.2.0"

#define TEAM_SUPER   2
#define MAX_MARCAS   32
#define MAX_EXTRA    8
// Material OFICIAL del juego: blanco y con $ignorez (se ve a traves de paredes). Como
// viene en los archivos del juego, todos lo tienen y sv_pure 2 no lo bloquea. (Antes se
// usaba un material propio que los demas jugadores no tenian y no veian la marca.)
#define MAT_BEAM     "materials/sprites/white.vmt"

/*=========================================================================
| ClubCampestre - Marcar
|
| Solo supervivientes. Se marca eligiendo "Mirar" en el menu de voces (Z)
| o con !marcar.
|  - Apuntando a un objeto: el objeto brilla (color segun tipo), nada mas.
|  - Apuntando a una ubicacion: circulo blanco en el piso + flechita "v"
|    blanca flotando encima, rebotando. Los objetos dentro del circulo brillan.
| Todo se ve a traves de paredes y solo lo ven los supervivientes.
=========================================================================*/

int g_iBeam;

ConVar g_cvAlcance;
ConVar g_cvDuracion;
ConVar g_cvDuracionGlow;
ConVar g_cvUsos;
ConVar g_cvCooldown;
ConVar g_cvVentana;
ConVar g_cvRadio;
ConVar g_cvAnilloAncho;
ConVar g_cvFlechaAncho;
ConVar g_cvFlechaAltura;
ConVar g_cvFlechaTam;
ConVar g_cvColor;
ConVar g_cvColorAuto;
ConVar g_cvZona;
ConVar g_cvSonido;
ConVar g_cvDebug;
ConVar g_cvTerreno;

#define SEGMENTOS_CIRCULO 12   // trozos del circulo cuando va en pared/rampa/techo

// Cargas / cooldown por jugador
int   g_iUsos[MAXPLAYERS + 1];
float g_fUltimoUso[MAXPLAYERS + 1];
float g_fCooldownFin[MAXPLAYERS + 1];
float g_fUltimoAviso[MAXPLAYERS + 1];

enum struct Marca
{
    bool  activo;
    bool  pin;                      // true = ubicacion (circulo + flecha); false = solo brillo de objeto
    float pos[3];
    float normal[3];                // hacia donde mira la superficie marcada (0,0,1 = piso)
    float expira;
    int   glow;                     // ref del brillo del objeto marcado directo
    int   fuente;                   // ref del objeto real marcado directo
    int   extras[MAX_EXTRA];        // refs de brillos de objetos dentro del circulo
    int   fuenteExtra[MAX_EXTRA];   // refs de esos objetos reales
}

Marca g_Marcas[MAX_MARCAS];

public Plugin myinfo =
{
    name        = "ClubCampestre - Marcar",
    author      = "Kydium",
    description = "Marcas de objetos y ubicaciones para supervivientes, con la voz 'Mirar'",
    version     = PLUGIN_VERSION,
    url         = ""
};

/*=========================================================================
| Inicio
=========================================================================*/
public void OnPluginStart()
{
    CreateConVar("cc_marcar_version", PLUGIN_VERSION, "Version del plugin", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvAlcance      = CreateConVar("cc_marcar_alcance",        "1500.0", "Distancia maxima para poder marcar", FCVAR_NOTIFY, true, 100.0, true, 5000.0);
    g_cvDuracion     = CreateConVar("cc_marcar_duracion",       "8.0",   "Segundos que dura la marca de ubicacion", FCVAR_NOTIFY, true, 1.0, true, 60.0);
    g_cvDuracionGlow = CreateConVar("cc_marcar_duracion_glow",  "15.0",   "Segundos que dura el brillo de un objeto marcado", FCVAR_NOTIFY, true, 1.0, true, 120.0);
    g_cvUsos         = CreateConVar("cc_marcar_usos",           "5",      "Marcas seguidas permitidas antes del cooldown", FCVAR_NOTIFY, true, 1.0, true, 50.0);
    g_cvCooldown     = CreateConVar("cc_marcar_cooldown",       "30.0",   "Segundos de espera al agotar las marcas seguidas", FCVAR_NOTIFY, true, 1.0, true, 300.0);
    g_cvVentana      = CreateConVar("cc_marcar_ventana",        "4.0",    "Si pasan mas de estos segundos entre marcas, el contador de spam se reinicia", FCVAR_NOTIFY, true, 1.0, true, 60.0);
    g_cvRadio        = CreateConVar("cc_marcar_radio",          "35.0",   "Radio del circulo del piso (tambien el radio en que se resaltan objetos cercanos)", FCVAR_NOTIFY, true, 10.0, true, 500.0);
    g_cvAnilloAncho  = CreateConVar("cc_marcar_anillo_ancho",   "2.0",    "Grosor del circulo del piso", FCVAR_NOTIFY, true, 0.5, true, 30.0);
    g_cvFlechaAncho  = CreateConVar("cc_marcar_flecha_ancho",   "2.0",    "Grosor de la flechita", FCVAR_NOTIFY, true, 0.5, true, 20.0);
    g_cvFlechaAltura = CreateConVar("cc_marcar_flecha_altura",  "25.0",   "Altura a la que flota la flechita sobre el piso", FCVAR_NOTIFY, true, 0.0, true, 300.0);
    g_cvFlechaTam    = CreateConVar("cc_marcar_flecha_tam",     "6.0",    "Tamano de la flechita", FCVAR_NOTIFY, true, 1.0, true, 50.0);
    g_cvColor        = CreateConVar("cc_marcar_color",          "255 180 40 255", "Color del brillo para objetos sin color de tipo (R G B A)", FCVAR_NOTIFY);
    g_cvColorAuto    = CreateConVar("cc_marcar_colorauto",      "1",      "Color segun tipo: meds=verde, lanzables=naranja, municion=amarillo (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvZona         = CreateConVar("cc_marcar_zona",           "0",      "Al marcar una ubicacion, hacer brillar los objetos dentro del circulo (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvSonido       = CreateConVar("cc_marcar_sonido",         "ui/bigreward.wav", "Sonido al marcar (vacio = sin sonido)", FCVAR_NOTIFY);
    g_cvTerreno      = CreateConVar("cc_marcar_terreno",        "1",      "La marca se acomoda a la superficie: en paredes, rampas y techos el circulo queda pegado a ella (0 = siempre horizontal)", FCVAR_NOTIFY, true, 0.0, true, 1.0);
    g_cvDebug        = CreateConVar("cc_marcar_debug",          "0",      "Muestra en la consola del jugador la linea de voz recibida (0/1)", FCVAR_NOTIFY, true, 0.0, true, 1.0);

    RegConsoleCmd("sm_marcar", Cmd_Marcar, "Marca el objeto o lugar al que apuntas");
    AddCommandListener(Listener_Vocalize, "vocalize");

    HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);

    // Las refs arrancan en -1 (si quedaran en 0 apuntarian al "world")
    for (int i = 0; i < MAX_MARCAS; i++)
        ResetMarca(i);

    CreateTimer(0.5, Timer_Marcas, _, TIMER_REPEAT);   // circulo + limpieza
    CreateTimer(0.1, Timer_Flecha, _, TIMER_REPEAT);   // flechita animada

    AutoExecConfig(true, "cc_marcar");
}

public void OnPluginEnd()
{
    BorrarTodas();
}

public void OnMapStart()
{
    g_iBeam = PrecacheModel(MAT_BEAM, true);

    // Las entidades del mapa anterior ya no existen: solo se limpia el estado
    for (int i = 0; i < MAX_MARCAS; i++)
        ResetMarca(i);
}

void Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
    BorrarTodas();
}

public void OnClientPutInServer(int client)
{
    g_iUsos[client]        = 0;
    g_fUltimoUso[client]   = 0.0;
    g_fCooldownFin[client] = 0.0;
    g_fUltimoAviso[client] = 0.0;
}


/*=========================================================================
| Como se marca: voz "Mirar" (Z) o !marcar
=========================================================================*/
// El menu de la Z manda "vocalize smartlook". Los avisos automaticos del juego
// ("mira, pastillas" al ver un objeto) usan el mismo comando pero con "auto",
// esos se ignoran. La voz se sigue escuchando normal.
public Action Listener_Vocalize(int client, const char[] command, int argc)
{
    if (!EsSupervivienteHumano(client))
        return Plugin_Continue;

    char linea[64], todo[128];
    GetCmdArg(1, linea, sizeof(linea));
    GetCmdArgString(todo, sizeof(todo));

    if (g_cvDebug.BoolValue)
        PrintToConsole(client, "[cc_marcar] vocalize: %s", todo);

    if (StrContains(todo, "auto", false) != -1)
        return Plugin_Continue;

    if (StrEqual(linea, "smartlook", false)
     || StrEqual(linea, "PlayerLook", false)
     || StrEqual(linea, "PlayerLookHere", false))
    {
        IntentarMarcar(client);
    }

    return Plugin_Continue;
}

public Action Cmd_Marcar(int client, int args)
{
    if (EsSupervivienteHumano(client))
        IntentarMarcar(client);
    return Plugin_Handled;
}

bool EsSupervivienteHumano(int client)
{
    return client >= 1 && client <= MaxClients
        && IsClientInGame(client) && !IsFakeClient(client)
        && GetClientTeam(client) == TEAM_SUPER && IsPlayerAlive(client);
}

void IntentarMarcar(int client)
{
    float ahora = GetEngineTime();

    // Cooldown activo: aviso personal (maximo uno por segundo)
    if (g_fCooldownFin[client] > ahora)
    {
        if (ahora - g_fUltimoAviso[client] > 1.0)
        {
            g_fUltimoAviso[client] = ahora;
            int restante = RoundToCeil(g_fCooldownFin[client] - ahora);
            PrintToChat(client, "\x04[✖]\x01 En espera: te faltan \x05%d\x01 s para volver a marcar.", restante);
        }
        return;
    }

    // Termino el cooldown, o dejo pasar la ventana sin spamear -> cargas llenas
    if (g_fCooldownFin[client] != 0.0)
    {
        g_fCooldownFin[client] = 0.0;
        g_iUsos[client] = 0;
    }
    else if (g_iUsos[client] > 0 && (ahora - g_fUltimoUso[client]) > g_cvVentana.FloatValue)
    {
        g_iUsos[client] = 0;
    }

    // Rayo desde los ojos
    float vEye[3], vAng[3], vEnd[3];
    GetClientEyePosition(client, vEye);
    GetClientEyeAngles(client, vAng);

    Handle tr = TR_TraceRayFilterEx(vEye, vAng, MASK_SHOT, RayType_Infinite, FiltroTrace, client);
    if (!TR_DidHit(tr))
    {
        delete tr;
        return;
    }
    float vNormal[3];
    TR_GetEndPosition(vEnd, tr);
    TR_GetPlaneNormal(tr, vNormal);
    int entidad = TR_GetEntityIndex(tr);
    delete tr;

    if (GetVectorDistance(vEye, vEnd) > g_cvAlcance.FloatValue)
        return;

    // Sin acomodarse al terreno (o normal invalida): siempre como si fuera piso
    if (!g_cvTerreno.BoolValue || GetVectorLength(vNormal) < 0.5)
    {
        vNormal[0] = 0.0; vNormal[1] = 0.0; vNormal[2] = 1.0;
    }
    NormalizeVector(vNormal, vNormal);

    CrearMarca(vEnd, vNormal, entidad);

    // Consumir carga
    g_iUsos[client]++;
    g_fUltimoUso[client] = ahora;
    if (g_iUsos[client] >= g_cvUsos.IntValue)
        g_fCooldownFin[client] = ahora + g_cvCooldown.FloatValue;
}

// El rayo atraviesa al que marca, jugadores, infectados comunes y brujas
public bool FiltroTrace(int entity, int contentsMask, any data)
{
    if (entity == data)
        return false;
    if (entity >= 1 && entity <= MaxClients)
        return false;

    if (entity > MaxClients && IsValidEntity(entity))
    {
        char cls[32];
        GetEntityClassname(entity, cls, sizeof(cls));
        if (StrEqual(cls, "infected") || StrEqual(cls, "witch"))
            return false;
    }
    return true;
}

/*=========================================================================
| Crear marcas
=========================================================================*/
void CrearMarca(const float pos[3], const float normal[3], int entidad)
{
    int slot = SlotLibre();
    g_Marcas[slot].activo = true;
    g_Marcas[slot].pos    = pos;
    g_Marcas[slot].normal = normal;

    // Apunto a un objeto? -> solo brillo, sin circulo ni flecha
    char cls[64], model[PLATFORM_MAX_PATH];
    if (EsObjeto(entidad, cls, sizeof(cls), model, sizeof(model)))
    {
        int color[3];
        ColorObjeto(cls, color);

        float oPos[3], oAng[3];
        GetEntPropVector(entidad, Prop_Data, "m_vecAbsOrigin", oPos);
        GetEntPropVector(entidad, Prop_Data, "m_angAbsRotation", oAng);

        g_Marcas[slot].glow = CrearGlow(model, oPos, oAng, color);
        if (g_Marcas[slot].glow != -1)
        {
            g_Marcas[slot].pin    = false;
            g_Marcas[slot].fuente = EntIndexToEntRef(entidad);
            g_Marcas[slot].expira = GetEngineTime() + g_cvDuracionGlow.FloatValue;
            SonidoMarca();
            return;
        }
        // Si el brillo no se pudo crear, cae a marca de ubicacion
    }

    // Ubicacion -> circulo + flecha, y brillo a los objetos dentro del circulo
    g_Marcas[slot].pin    = true;
    g_Marcas[slot].expira = GetEngineTime() + g_cvDuracion.FloatValue;

    if (g_cvZona.BoolValue)
        BrillarCercanos(slot);

    DibujarCirculo(slot);
    SonidoMarca();
}

int SlotLibre()
{
    for (int i = 0; i < MAX_MARCAS; i++)
    {
        if (!g_Marcas[i].activo)
            return i;
    }

    // Todo lleno: se reemplaza la que vence primero
    int slot = 0;
    for (int i = 1; i < MAX_MARCAS; i++)
    {
        if (g_Marcas[i].expira < g_Marcas[slot].expira)
            slot = i;
    }
    BorrarMarca(slot);
    return slot;
}

// Objetos recogibles: todos empiezan por "weapon_" (armas, meds, lanzables, municion...)
bool EsObjeto(int entidad, char[] cls, int clsLen, char[] model, int modelLen)
{
    if (entidad <= MaxClients || !IsValidEntity(entidad))
        return false;
    if (!GetEntityClassname(entidad, cls, clsLen) || StrContains(cls, "weapon_") != 0)
        return false;
    if (GetEntPropEnt(entidad, Prop_Data, "m_hOwnerEntity") > 0)   // lo tiene alguien en la mano
        return false;

    GetEntPropString(entidad, Prop_Data, "m_ModelName", model, modelLen);
    return model[0] != '\0';
}

void BrillarCercanos(int slot)
{
    float radio = g_cvRadio.FloatValue;
    int count = 0;
    int maxEnt = GetMaxEntities();
    char cls[64], model[PLATFORM_MAX_PATH];
    float ePos[3], eAng[3];

    for (int e = MaxClients + 1; e < maxEnt && count < MAX_EXTRA; e++)
    {
        if (!EsObjeto(e, cls, sizeof(cls), model, sizeof(model)))
            continue;

        GetEntPropVector(e, Prop_Data, "m_vecAbsOrigin", ePos);
        if (GetVectorDistance(g_Marcas[slot].pos, ePos) > radio)
            continue;
        GetEntPropVector(e, Prop_Data, "m_angAbsRotation", eAng);

        int color[3];
        ColorObjeto(cls, color);

        int ref = CrearGlow(model, ePos, eAng, color);
        if (ref != -1)
        {
            g_Marcas[slot].extras[count]      = ref;
            g_Marcas[slot].fuenteExtra[count] = EntIndexToEntRef(e);
            count++;
        }
    }
}

void ColorObjeto(const char[] c, int color[3])
{
    // Color por defecto (cc_marcar_color)
    char buffer[32], partes[4][8];
    g_cvColor.GetString(buffer, sizeof(buffer));
    int n = ExplodeString(buffer, " ", partes, sizeof(partes), sizeof(partes[]));
    color[0] = (n > 0) ? StringToInt(partes[0]) : 255;
    color[1] = (n > 1) ? StringToInt(partes[1]) : 180;
    color[2] = (n > 2) ? StringToInt(partes[2]) : 40;

    if (!g_cvColorAuto.BoolValue)
        return;

    if (StrContains(c, "first_aid_kit") != -1 || StrContains(c, "pain_pills") != -1
     || StrContains(c, "adrenaline")    != -1 || StrContains(c, "defibrillator") != -1)
    {
        color[0] = 60;  color[1] = 220; color[2] = 90;    // verde: curacion
    }
    else if (StrContains(c, "molotov") != -1 || StrContains(c, "pipe_bomb") != -1
          || StrContains(c, "vomitjar") != -1)
    {
        color[0] = 255; color[1] = 90;  color[2] = 40;    // naranja: lanzables
    }
    else if (StrContains(c, "ammo") != -1)
    {
        color[0] = 255; color[1] = 220; color[2] = 60;    // amarillo: municion
    }
    else if (StrContains(c, "gascan") != -1 || StrContains(c, "oxygentank") != -1
          || StrContains(c, "propanetank") != -1)
    {
        color[0] = 255; color[1] = 140; color[2] = 40;    // naranja fuerte: explosivos
    }
}

// Copia invisible del objeto en su mismo lugar, que solo muestra el contorno brillante
int CrearGlow(const char[] model, const float pos[3], const float ang[3], const int color[3])
{
    int ent = CreateEntityByName("prop_dynamic_override");
    if (ent == -1)
        return -1;

    PrecacheModel(model);
    DispatchKeyValue(ent, "model", model);
    DispatchKeyValue(ent, "solid", "0");
    DispatchKeyValue(ent, "disableshadows", "1");

    if (!DispatchSpawn(ent))
    {
        RemoveEntity(ent);
        return -1;
    }

    SetEntityMoveType(ent, MOVETYPE_NONE);
    TeleportEntity(ent, pos, ang, NULL_VECTOR);

    // Modelo invisible: solo queda el contorno
    SetEntityRenderMode(ent, RENDER_TRANSCOLOR);
    SetEntityRenderColor(ent, 255, 255, 255, 0);

    SetEntProp(ent, Prop_Send, "m_iGlowType", 3);
    SetEntProp(ent, Prop_Send, "m_glowColorOverride", color[0] + (color[1] << 8) + (color[2] << 16));
    SetEntProp(ent, Prop_Send, "m_nGlowRange", 0);
    SetEntProp(ent, Prop_Send, "m_nGlowRangeMin", 0);

    // Solo los supervivientes lo ven
    SDKHook(ent, SDKHook_SetTransmit, Hook_GlowTransmit);

    return EntIndexToEntRef(ent);
}

public Action Hook_GlowTransmit(int entity, int client)
{
    if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SUPER)
        return Plugin_Continue;
    return Plugin_Handled;
}

void SonidoMarca()
{
    char sonido[PLATFORM_MAX_PATH];
    g_cvSonido.GetString(sonido, sizeof(sonido));
    if (sonido[0] == '\0')
        return;

    // "play" suena en el propio cliente (tambien funciona en listen server)
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SUPER)
            ClientCommand(i, "play %s", sonido);
    }
}

/*=========================================================================
| Dibujo: circulo blanco en el piso + flechita blanca rebotando
=========================================================================*/
int ListaSupervivientes(int[] clientes)
{
    int total = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == TEAM_SUPER)
            clientes[total++] = i;
    }
    return total;
}

void DibujarCirculo(int slot)
{
    int clientes[MAXPLAYERS];
    int total = ListaSupervivientes(clientes);
    if (total == 0)
        return;

    float n[3];
    n = g_Marcas[slot].normal;
    int blanco[4] = {255, 255, 255, 255};
    float radio  = g_cvRadio.FloatValue;
    float grosor = g_cvAnilloAncho.FloatValue;

    // Apenas separado de la superficie para que no se hunda en ella
    float centro[3];
    for (int k = 0; k < 3; k++)
        centro[k] = g_Marcas[slot].pos[k] + n[k] * 2.0;

    // Piso (casi plano): el mismo circulo de siempre
    if (n[2] > 0.98)
    {
        // Mismo diametro inicial y final = circulo fijo (no se expande)
        float diametro = radio * 2.0;
        TE_SetupBeamRingPoint(centro, diametro, diametro + 0.1, g_iBeam, 0, 0, 0, 0.6,
                              grosor, 0.0, blanco, 0, 0);
        TE_Send(clientes, total);
        return;
    }

    // Pared, rampa o techo: circulo armado con segmentos, en el plano de la superficie
    float u[3], v[3];
    EjesDelPlano(n, u, v);

    float a, p1[3], p2[3];
    float paso = (2.0 * FLOAT_PI) / float(SEGMENTOS_CIRCULO);
    for (int s = 0; s < SEGMENTOS_CIRCULO; s++)
    {
        a = paso * float(s);
        for (int k = 0; k < 3; k++)
            p1[k] = centro[k] + (u[k] * Cosine(a) + v[k] * Sine(a)) * radio;
        a = paso * float(s + 1);
        for (int k = 0; k < 3; k++)
            p2[k] = centro[k] + (u[k] * Cosine(a) + v[k] * Sine(a)) * radio;

        TE_SetupBeamPoints(p1, p2, g_iBeam, 0, 0, 0, 0.6, grosor, grosor, 0, 0.0, blanco, 0);
        TE_Send(clientes, total);
    }
}

// Dos ejes perpendiculares entre si que forman el plano de la superficie (normal n)
void EjesDelPlano(const float n[3], float u[3], float v[3])
{
    float ref[3] = {0.0, 0.0, 1.0};
    if (FloatAbs(n[2]) > 0.9)          // casi piso o techo: otra referencia
    {
        ref[0] = 1.0; ref[2] = 0.0;
    }
    GetVectorCrossProduct(n, ref, u);
    NormalizeVector(u, u);
    GetVectorCrossProduct(n, u, v);
    NormalizeVector(v, v);
}

// La "v" sale de la superficie (piso, pared o techo) y apunta hacia ella. Se dibuja de
// frente a cada jugador, para que siempre se vea como "v".
void DibujarFlecha(int slot, int client, float rebote)
{
    float n[3];
    n = g_Marcas[slot].normal;

    // Direccion del jugador hacia la marca
    float ojo[3], dir[3];
    GetClientEyePosition(client, ojo);
    SubtractVectors(g_Marcas[slot].pos, ojo, dir);

    // "Lado" de la v: perpendicular a la normal y a la mirada del jugador
    float der[3];
    GetVectorCrossProduct(n, dir, der);
    if (GetVectorLength(der) < 0.01)
    {
        float otroEje[3];
        EjesDelPlano(n, der, otroEje);   // mirando justo de frente: cualquier eje del plano
    }
    NormalizeVector(der, der);

    float tam    = g_cvFlechaTam.FloatValue;
    float grosor = g_cvFlechaAncho.FloatValue;
    int blanco[4] = {255, 255, 255, 255};

    // Punta separada de la superficie (cc_marcar_flecha_altura) + rebote; los brazos
    // se abren hacia afuera, alejandose de la superficie
    float alto = g_cvFlechaAltura.FloatValue + rebote;
    float punta[3], izq[3], dch[3];
    for (int k = 0; k < 3; k++)
    {
        punta[k] = g_Marcas[slot].pos[k] + n[k] * alto;
        izq[k]   = punta[k] - der[k] * tam + n[k] * tam * 0.8;
        dch[k]   = punta[k] + der[k] * tam + n[k] * tam * 0.8;
    }

    // Cada brazo se alarga un poco pasando la punta, para que se crucen y no quede hueco
    float extIzq[3], extDch[3], v[3];
    float extra = grosor * 0.6 + 0.5;

    SubtractVectors(punta, izq, v);
    NormalizeVector(v, v);
    ScaleVector(v, extra);
    AddVectors(punta, v, extIzq);

    SubtractVectors(punta, dch, v);
    NormalizeVector(v, v);
    ScaleVector(v, extra);
    AddVectors(punta, v, extDch);

    TE_SetupBeamPoints(izq, extIzq, g_iBeam, 0, 0, 0, 0.12, grosor, grosor, 0, 0.0, blanco, 0);
    TE_SendToClient(client);
    TE_SetupBeamPoints(dch, extDch, g_iBeam, 0, 0, 0, 0.12, grosor, grosor, 0, 0.0, blanco, 0);
    TE_SendToClient(client);
}

/*=========================================================================
| Timers
=========================================================================*/
// Cada 0.5s: vencer marcas, quitar brillos de objetos recogidos y redibujar circulos
public Action Timer_Marcas(Handle timer)
{
    float ahora = GetEngineTime();

    for (int i = 0; i < MAX_MARCAS; i++)
    {
        if (!g_Marcas[i].activo)
            continue;

        if (ahora >= g_Marcas[i].expira)
        {
            BorrarMarca(i);
            continue;
        }

        // Recogieron el objeto marcado -> fuera su brillo (y la marca, que era solo eso)
        if (g_Marcas[i].fuente != -1 && EntRefToEntIndex(g_Marcas[i].fuente) == -1)
        {
            BorrarMarca(i);
            continue;
        }

        // Recogieron algun objeto que estaba dentro del circulo -> fuera su brillo
        for (int k = 0; k < MAX_EXTRA; k++)
        {
            if (g_Marcas[i].fuenteExtra[k] != -1 && EntRefToEntIndex(g_Marcas[i].fuenteExtra[k]) == -1)
            {
                QuitarEntidad(g_Marcas[i].extras[k]);
                g_Marcas[i].extras[k]      = -1;
                g_Marcas[i].fuenteExtra[k] = -1;
            }
        }

        if (g_Marcas[i].pin)
            DibujarCirculo(i);
    }
    return Plugin_Continue;
}

// Cada 0.1s: flechita con rebote suave (un ciclo cada ~1.6s, 3 unidades arriba/abajo)
public Action Timer_Flecha(Handle timer)
{
    float ahora  = GetEngineTime();
    float rebote = Sine(ahora * 4.0) * 3.0;

    for (int i = 0; i < MAX_MARCAS; i++)
    {
        if (!g_Marcas[i].activo || !g_Marcas[i].pin || ahora >= g_Marcas[i].expira)
            continue;

        for (int c = 1; c <= MaxClients; c++)
        {
            if (IsClientInGame(c) && !IsFakeClient(c) && GetClientTeam(c) == TEAM_SUPER)
                DibujarFlecha(i, c, rebote);
        }
    }
    return Plugin_Continue;
}

/*=========================================================================
| Limpieza
=========================================================================*/
void ResetMarca(int i)
{
    g_Marcas[i].activo = false;
    g_Marcas[i].pin    = false;
    g_Marcas[i].expira = 0.0;
    g_Marcas[i].normal[0] = 0.0;
    g_Marcas[i].normal[1] = 0.0;
    g_Marcas[i].normal[2] = 1.0;
    g_Marcas[i].glow   = -1;
    g_Marcas[i].fuente = -1;
    for (int k = 0; k < MAX_EXTRA; k++)
    {
        g_Marcas[i].extras[k]      = -1;
        g_Marcas[i].fuenteExtra[k] = -1;
    }
}

void BorrarMarca(int i)
{
    QuitarEntidad(g_Marcas[i].glow);
    for (int k = 0; k < MAX_EXTRA; k++)
        QuitarEntidad(g_Marcas[i].extras[k]);
    ResetMarca(i);
}

void BorrarTodas()
{
    for (int i = 0; i < MAX_MARCAS; i++)
    {
        if (g_Marcas[i].activo)
            BorrarMarca(i);
    }
}

void QuitarEntidad(int ref)
{
    if (ref == -1)
        return;

    int ent = EntRefToEntIndex(ref);
    if (ent != -1 && IsValidEntity(ent))
    {
        SDKUnhook(ent, SDKHook_SetTransmit, Hook_GlowTransmit);
        RemoveEntity(ent);
    }
}
