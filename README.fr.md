# MatrixNet

[English](./README.md) · [简体中文](./README.zh-CN.md) · [繁體中文](./README.zh-Hant.md) · [日本語](./README.ja.md) · [한국어](./README.ko.md) · **Français** · [Deutsch](./README.de.md) · [Español](./README.es.md)

**Voyez quelle app parle à quelle IP — puis descendez n'importe quel flux jusqu'au paquet.**

Un moniteur réseau et analyseur de paquets approfondi pour macOS, 100 % natif SwiftUI. Aussi simple que le Moniteur d'activité pour savoir *qui est sur le réseau*, aussi profond que Wireshark pour *ce qui circule sur le fil* — et chaque paquet sait quelle app l'a envoyé.

[![CI](https://github.com/MatrixReligio/MatrixNet/actions/workflows/ci.yml/badge.svg)](https://github.com/MatrixReligio/MatrixNet/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](./LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2026%2B-black)](#configuration-requise)
[![Swift](https://img.shields.io/badge/Swift-6-orange)](https://swift.org)
[![Release](https://img.shields.io/github/v/release/MatrixReligio/MatrixNet?sort=semver&color=brightgreen)](https://github.com/MatrixReligio/MatrixNet/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/MatrixReligio/MatrixNet/total?label=downloads&color=success)](https://github.com/MatrixReligio/MatrixNet/releases)
[![Stars](https://img.shields.io/github/stars/MatrixReligio/MatrixNet?color=yellow)](https://github.com/MatrixReligio/MatrixNet/stargazers)
[![Last commit](https://img.shields.io/github/last-commit/MatrixReligio/MatrixNet)](https://github.com/MatrixReligio/MatrixNet/commits/main)
[![Notarized](https://img.shields.io/badge/Developer%20ID-notarized-success?logo=apple&logoColor=white)](#installation)
[![Passive](https://img.shields.io/badge/passive-zero--conflict-8A2BE2)](#confidentialité)
[![No telemetry](https://img.shields.io/badge/telemetry-none-success)](#confidentialité)

> **État : Phase 1, en cours de développement.** MatrixNet est un projet à un stade précoce, en développement actif. L'architecture est arrêtée et les bibliothèques de base sont construites en test-first, mais l'app n'est pas encore complète et il n'y a pas de version stable. Les interfaces, commandes et l'UI peuvent changer.

---

## Qu'est-ce que MatrixNet ?

Depuis une décennie, deux outils règnent sur le réseau macOS. **Little Snitch** vous dit *quelle app* se connecte où. **Wireshark** montre *chaque octet sur le fil* — sans savoir quelle app l'a produit. MatrixNet réunit les deux dans une seule app native : la surveillance des connexions par app au-dessus, la dissection au niveau paquet en dessous, et une couche de corrélation qui relie chaque paquet capturé au processus et à la connexion auxquels il appartient.

La phase 1 est strictement **passive — observer, jamais bloquer**. Pas de pare-feu, pas d'interception du trafic, pas de déchiffrement HTTPS (voir la [Feuille de route](#feuille-de-route) pour la suite). Comme elle se contente d'observer, MatrixNet fonctionne aux côtés du proxy, du filtre ou du VPN que vous utilisez déjà, sans les gêner.

## Fonctionnalités

### 🔭 Surveillance des connexions
- Un **tableau de bord Aperçu** en direct : graphe de débit (dernière minute), indicateurs clés (connexions actives, total de session, apps actives, pays atteints, connexions à risque, part via proxy), répartition des protocoles, principaux pays de destination et une liste enrichie des plus gros consommateurs.
- Liste des connexions en direct à l'échelle du système, par app : processus, hôte/IP distant, pays, débit montant/descendant, octets cumulés et cycle de vie de la connexion.
- Attribution des processus par le noyau — le même mécanisme que `nettop` et le Moniteur d'activité — donc une attribution exacte sans course au polling.
- **Rôle client/serveur** déduit des ports (cet hôte a-t-il initié ou accepté la connexion ?).
- **Conscience des proxys et VPN/tunnels** — les connexions dont le distant est votre proxy configuré ou local sont signalées, et les processus qui relaient le trafic d'autres apps (tunnels NetworkExtension) portent un badge, pour voir clairement quand le trafic est routé.
- **Marquage des IP à risque** — les adresses distantes figurant sur une liste publique de renseignement de menaces sont signalées par un badge ⚠️ (à titre indicatif — MatrixNet étiquette, ne bloque jamais).
- L'enrichissement DNS remonte des IP observées vers les noms d'hôtes, avec une bascule en un clic pour afficher **noms de domaine ou IP brutes** dans les vues Connexions et Paquets.
- Un **onglet Carte** dessine un globe pointillé du monde réel, hors ligne (Natural Earth, sans tuiles), avec des arcs lumineux de ce Mac vers chaque pays auquel il parle — taille des nœuds selon le nombre de connexions, destinations à risque en rouge.
- Un historique des connexions consultable (« quelle app s'est connectée où hier »).

### 🔬 Analyse approfondie des paquets
- Capture paquet par paquet où **chaque paquet porte le PID propriétaire**.
- Dissection solide des protocoles les plus importants : **Ethernet, IPv4, IPv6, TCP, UDP, ICMP, DNS, TLS (handshake / SNI / certificat) et HTTP/1.1**.
- Une vue à trois volets façon Wireshark : liste des paquets, arbre de détail des protocoles et hexa synchronisé.
- Réassemblage Suivre le flux et un langage de filtres d'affichage pour découper la capture.
- Filtrage des paquets jusqu'à une seule app ou une seule connexion.
- Export des paquets sélectionnés ou de sessions entières en **pcapng** — avec les métadonnées de processus par paquet — pour les passer à Wireshark.

### 🖥️ Widget de bureau
- Un widget WidgetKit (petit / moyen / grand) affiche en direct le nombre de connexions actives, le débit montant/descendant, les totaux de session, les apps les plus actives et un compteur de menaces — sur le bureau ou dans le centre de notifications.

### 🧭 Barre des menus et arrière-plan
- Présent dans la **barre des menus** avec un débit ↓/↑ en direct, et continue de surveiller après la fermeture de la fenêtre principale — pour que le widget ne soit jamais obsolète.
- Un **mode barre des menus uniquement** optionnel masque entièrement l'icône du Dock.
- **Lancement à l'ouverture de session** et une **fenêtre Réglages** (⌘,) pour le mode arrière-plan, les notifications de connexions à risque, la recherche automatique de mises à jour et l'actualisation à la demande des jeux de données.
- **Notifications de connexions à risque** — vous alertent quand une connexion active atteint une adresse signalée (à titre indicatif ; MatrixNet ne bloque jamais).

### 🌍 Parle votre langue
- Entièrement localisé en **8 langues** — anglais, chinois simplifié et traditionnel, japonais, coréen, français, allemand et espagnol — en suivant automatiquement la langue système de macOS. La couverture des traductions est vérifiée en CI.

### 🔄 Toujours à jour
- **Mise à jour automatique intégrée** via [Sparkle](https://sparkle-project.org), avec des mises à jour signées EdDSA servies depuis les Releases GitHub. À la demande ou en arrière-plan chaque jour.
- La **base GeoIP s'actualise automatiquement** en arrière-plan depuis le jeu de données mensuel DB-IP, pour que l'attribution par pays reste juste dans le temps.
- La **liste d'IP à risque s'actualise automatiquement** de la même façon, depuis l'agrégat public IPsum — l'app ne contacte jamais que sa propre ressource de version, jamais les flux en amont.

### 🛡️ Confidentialité et zéro conflit
- **Zéro conflit par conception.** MatrixNet est entièrement passif : aucun NetworkExtension, aucune réservation exclusive de routage/proxy, jamais sur le chemin des paquets. Il coexiste avec AdGuard, Surge, Little Snitch, LuLu et tout VPN.
- **100 % local.** Tout le traitement a lieu sur votre machine. Aucune donnée ne quitte l'appareil. Pas de télémétrie. Pas de compte. Pas de cloud.
- **Moindre privilège.** La surveillance des connexions ne demande aucune autorisation. La capture de paquets est isolée dans un assistant minimal dédié à la capture ; l'analyse des octets non fiables s'exécute dans l'app non privilégiée.

## Pourquoi MatrixNet ?

| | Little Snitch | Wireshark | **MatrixNet (Phase 1)** |
|---|:---:|:---:|:---:|
| Vue des connexions par app | ✅ | ❌ | ✅ |
| Dissection au niveau paquet | ❌ | ✅ | ✅ |
| Chaque paquet connaît son app | ❌ | ❌ | ✅ |
| Corrélation connexion ↔ paquet | ❌ | ❌ | ✅ |
| Coexiste avec proxys/VPN | ⚠️ | ✅ | ✅ |
| App macOS native et légère | ✅ | ❌ | ✅ |
| Bloque/filtre le trafic | ✅ | ❌ | ❌ (par conception — passif) |

MatrixNet ne cherche pas à remplacer un pare-feu. C'est l'outil vers lequel se tourner pour *comprendre* le comportement réseau de sa machine — d'une vue d'ensemble par app jusqu'aux octets — sans perturber le reste du système.

## Architecture

MatrixNet suit une conception **passive d'abord, à double source** (appelée en interne « Architecture A′ »). Deux sources passives indépendantes sont fusionnées par 5-uplet et PID :

- **Le niveau connexion** provient du framework privé `NetworkStatistics` d'Apple (`NStatManager*`) — le mécanisme noyau derrière `nettop` et le Moniteur d'activité. Le noyau attribue chaque connexion à un PID et rapporte le 5-uplet et les compteurs d'octets. Cela ne demande ni root, ni entitlement, ni NetworkExtension, ce qui explique précisément pourquoi MatrixNet n'entre en conflit avec rien.
- **Le niveau paquet** provient de `PKTAP` (`DLT_PKTAP`) au-dessus de BPF, qui étiquette chaque paquet avec son PID d'origine. Quand un VPN est actif, MatrixNet capture à la fois l'interface physique (`en0`) et le(s) tunnel(s) (`utun*`). La capture brute exige root, elle vit donc dans un petit assistant privilégié enregistré via `SMAppService`. L'assistant *ne fait que capturer* — toute la dissection des données réseau non fiables se passe dans l'app principale non privilégiée.

```mermaid
flowchart TB
    subgraph App["MatrixNet.app — SwiftUI, non-sandboxed, Hardened Runtime"]
        NS["Connection monitor<br/>NetworkStatistics (in-process, no privilege)"]
        CORR["Correlation engine + protocol dissection<br/>persistence + pcapng + UI"]
        XPCC["XPC client"]
        NS --> CORR
        CORR --- XPCC
    end
    subgraph Helper["com.matrixreligio.matrixnet.helper — root daemon (SMAppService)"]
        CAP["PKTAP / BPF raw capture only<br/>en0 + utun*, no parsing"]
    end
    XPCC <-->|"XPC: raw packet stream + control"| CAP
```

**Pourquoi pas de NetworkExtension ?** Sur macOS, attribuer le trafic à un processus *ne nécessite pas* NetworkExtension — le noyau le fait déjà via `NetworkStatistics`. Utiliser `NEFilterDataProvider`, `NEPacketTunnelProvider` ou `NEDNSProxyProvider` reviendrait à se disputer des emplacements exclusifs et contestés dans le chemin socket/routage/DNS, source documentée des conflits entre produits de filtrage. Pour un outil de surveillance, l'observation passive du noyau satisfait parfaitement l'exigence de zéro conflit.

Voir [`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) pour la conception complète, le graphe de dépendances des modules et les flux de données.

## Configuration requise

- **macOS 26 (Tahoe)** ou ultérieur
- Apple Silicon ou Intel
- Pour compiler depuis les sources : **Xcode 26** et [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Installation

Téléchargez le `.dmg` notarié depuis la page des [Releases GitHub](https://github.com/MatrixReligio/MatrixNet/releases), ouvrez-le et glissez MatrixNet dans votre dossier Applications. Les builds sont signés avec un Developer ID et notariés par Apple, donc Gatekeeper les ouvre sans avertissement. Une fois installé, MatrixNet se maintient à jour — inutile de revenir sur cette page.

MatrixNet **n'est pas** distribué via le Mac App Store : la capture BPF/PKTAP et le framework `NetworkStatistics` ne sont pas disponibles pour les apps en bac à sable. La distribution directe et notariée est une conséquence architecturale délibérée, pas un oubli.

## Compiler depuis les sources

> Les commandes ci-dessous sont des espaces réservés et **seront finalisées** à mesure que les scripts de build et d'empaquetage arrivent.

```sh
# 1. Cloner
git clone https://github.com/MatrixReligio/MatrixNet.git
cd MatrixNet

# 2. Lancer la suite de tests du cœur logique pur (sans Xcode)
swift test

# 3. Générer le projet Xcode (cibles App + assistant privilégié)
xcodegen generate

# 4. Compiler / lancer l'app
#    (ouvrir MatrixNet.xcodeproj dans Xcode 26, ou utiliser xcodebuild — à finaliser)
open MatrixNet.xcodeproj
```

Le cœur logique pur (modèle de domaine, dissection, pcapng, corrélation, etc.) est un Swift Package local : il se compile et se teste avec un simple `swift test`. L'app macOS et l'assistant privilégié sont des cibles Xcode générées par XcodeGen depuis `project.yml`. Voir [`CONTRIBUTING.md`](./CONTRIBUTING.md) pour le flux de développement complet.

## Autorisations

MatrixNet demande le *moindre* privilège à chaque niveau et se dégrade en douceur :

- **Surveillance des connexions — aucune autorisation requise.** Lancez l'app et vous voyez immédiatement quelles apps sont sur le réseau. `NetworkStatistics` s'exécute in-process, sans root, entitlement ni invite TCC.
- **Capture approfondie des paquets — une autorisation système unique.** La capture brute exige root, donc MatrixNet installe un assistant minimal dédié à la capture via `SMAppService`, ce qui requiert une seule approbation système. Si vous refusez ou si l'installation échoue, toutes les fonctions de surveillance des connexions continuent de marcher et seule la capture de paquets est désactivée (avec une invite de nouvelle tentative).

L'assistant existe uniquement pour satisfaire l'exigence root de BPF/PKTAP. Il ne fait aucune analyse — traiter des octets réseau non fiables reste volontairement hors du processus privilégié.

## Confidentialité

MatrixNet traite tout localement. Il n'envoie aucune donnée hors de votre machine, n'a pas de télémétrie, ne requiert aucun compte et ne parle à aucun serveur. Captures, historique et réglages ne vivent que sur votre disque.

## Feuille de route

La phase 1 se limite volontairement à la surveillance et à l'analyse passives. Prévu pour des phases ultérieures (non implémenté et non garanti) :

- **Pare-feu / blocage** — un mode d'interception optionnel (probablement via `NEFilterDataProvider`), avec un avertissement clair sur les conflits possibles avec d'autres filtres au niveau socket.
- **Analyse native par IA** — requêtes en langage naturel sur votre trafic, détection automatique de traqueurs / anomalies / fuites de vie privée.
- **Déchiffrement HTTPS (MITM)** — interception TLS optionnelle pour inspection en clair.
- Capture distante / mobile, un moteur de règles et une couverture de protocoles plus large façon Wireshark.

## Contribuer

Les contributions sont les bienvenues. MatrixNet est construit en test-first, avec concurrence stricte, SwiftLint/SwiftFormat et Conventional Commits. Merci de lire [`CONTRIBUTING.md`](./CONTRIBUTING.md) avant d'ouvrir une pull request, et de noter notre [Code de conduite](./CODE_OF_CONDUCT.md).

Les problèmes de sécurité doivent être signalés en privé — voir [`SECURITY.md`](./SECURITY.md).

## Licence

Sous licence [Apache License 2.0](./LICENSE). Copyright 2026 MatrixReligio LLC. Voir [`NOTICE`](./NOTICE) pour les attributions.

## Remerciements

MatrixNet se tient sur les épaules des outils qui ont fait de la transparence réseau une norme. Merci aux projets **Wireshark** et **tcpdump/libpcap** pour des décennies de travail de dissection et de capture, et à **Little Snitch** et **LuLu** pour avoir montré ce que peut être la conscience réseau par app sur macOS.

Données fournies : géolocalisation par pays par [DB-IP](https://db-ip.com) (CC-BY-4.0), liste d'IP à risque dérivée d'[IPsum](https://github.com/stamparm/ipsum) (domaine public), et géométrie mondiale de l'onglet Carte issue de [Natural Earth](https://www.naturalearthdata.com) (domaine public). Voir [`NOTICE`](./NOTICE) pour les attributions complètes.

---

Questions ou retours : [contact@matrixreligio.com](mailto:contact@matrixreligio.com)
