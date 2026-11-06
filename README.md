# MVAT – Tutor de Combate (WoW Classic / Classic Era)

Addon **leve, universal e 100% informativo** que mostra, num ícone flutuante próprio, a habilidade
recomendada para o momento: emergência, interrupção, dissipar, cura, provocar, combo de dano, área
(farm) ou buff ausente — junto com a **tecla de atalho** que você usa para ela.

> O addon **não automatiza nada**: não lança feitiços, não clica, não altera barras de ação.
> Ele só lê o estado do jogo e desenha um ícone.

## Recursos

- **Todas as 9 classes do Classic** (Guerreiro, Ladino, Mago, Sacerdote, Paladino, Caçador, Bruxo,
  Xamã, Druida), detectadas automaticamente no login (`UnitClass`).
- **Spell IDs** + `GetSpellInfo`/`C_Spell`: funciona em cliente Português ou Inglês.
- **Só sugere o que você já aprendeu** — o livro de feitiços é relido ao subir de nível, aprender
  feitiço ou mudar talentos. Qualquer rank conta.
- **Prioridades** (a primeira que se aplicar aparece):
  1. **EMERGÊNCIA** – vida baixa (Muralha de Escudo, Bloco de Gelo, Escudo Divino, Sumir…)
  2. **INTERROMPER** – alvo castando algo interrompível (Chute, Contrafeitiço, Choque Terreno…)
  3. **DEFESA** – cast pesado não‑interrompível vindo em você
  4. **DISSIPAR** – veneno/doença/maldição/magia em você ou no grupo/raide
  5. **CURA** – aliado mais ferido do grupo (o nome e a % aparecem no texto)
  6. **PROVOCAR** – tanque: o alvo está batendo em outro membro do grupo
  7. **COMBO** – reage a procs e buffs: Presença da Mente → Piroblasto, Clarividência → feitiço grátis,
     Transe Sombrio → Seta Sombria, Selo → Julgamento, pontos de combo → finalizador,
     Sobrepujar/Revanche/Executar (reativos), Rapidez da Natureza → cura instantânea…
  8. **ÁREA / FARM** – com vários inimigos (padrão 3+): Redemoinho, Explosão Arcana, Consagração,
     Nevasca, Tiro Múltiplo, Chuva de Fogo, Golpe Giratório, Totem de Magma…
  9. **DANO** – rotação básica single target (DoTs ausentes, golpe principal, filler)
  10. **BUFF** – buffs próprios ausentes (fora de combate)
- **Tecla de atalho** lida do mapa de bindings do jogo (`GetBindingKey`): binding direto do feitiço,
  barras da Blizzard, ElvUI, Bartender4 e Dominos — inclusive barras de postura/forma.
- **HUD independente** (âncora própria): não mexe no ElvUI nem nas barras padrão.
  Travado, ele não captura cliques.
- Posição, escala e opções salvas por **SavedVariables** (`MVAT_DB`).

## Instalação

1. Feche o jogo (ou faça logout).
2. Baixe este repositório: **Code → Download ZIP** (ou `git clone`).
3. Copie **a pasta `MVAT`** (a que contém `MVAT.toc` e `MVAT.lua`) para:
   - `World of Warcraft\_classic_era_\Interface\AddOns\` (Classic Era / Hardcore / SoD)
   - ou `World of Warcraft\_classic_\Interface\AddOns\` (Classic progressão)

   O resultado deve ser `...\Interface\AddOns\MVAT\MVAT.toc`.
   **Não** copie a pasta `MVAT-main` inteira — o nome da pasta precisa ser `MVAT`.
4. Abra o jogo, na tela de personagens clique em **AddOns** e marque **MVAT – Tutor de Combate**.
   Se aparecer "Desatualizado", marque **Carregar AddOns desatualizados**.
5. Entre no jogo. Você verá: `MVAT carregado para <classe>`.

**Dica:** ative as placas de nome de inimigos (tecla **V**) — o addon usa elas para contar quantos
mobs estão em combate e ativar as sugestões de área/farm.

## Comandos de chat (`/mvat` ou `/tutor`)

| Comando | Efeito |
|---|---|
| `/mvat` | Alterna travar/destravar a âncora e lista os comandos |
| `/mvat unlock` | Destrava: arraste o ícone com o botão esquerdo |
| `/mvat lock` | Trava e salva a posição |
| `/mvat scale 1.5` | Tamanho do ícone (0.5 a 3) |
| `/mvat aoe 3` | Quantos inimigos ativam o modo área/farm (2 a 10) |
| `/mvat combat` | Liga/desliga "mostrar só em combate" |
| `/mvat text` | Liga/desliga o texto explicativo abaixo do ícone |
| `/mvat barra` | Liga/desliga "só sugerir habilidades que estão nas suas barras" (padrão: ligado) |
| `/mvat selo <nome>` | Paladino: fixa um selo (`retidao`, `furia`, `cruzado`, `comando`, `luz`, `sabedoria`, `justica`) ou volta ao `auto` |
| `/mvat limpar` | Liga/desliga o painel LIMPAR (debuffs do grupo que você remove) |
| `/mvat casts` | Liga/desliga o painel de casts de outros inimigos (chefe, elites) |
| `/mvat test` | Mostra um ícone de teste por 5 segundos |
| `/mvat reset` | Restaura posição e opções padrão |
| `/mvat on` / `/mvat off` | Ativa / desativa o addon |
| `/mvat debug` | Mostra classe, n. de regras e habilidades reconhecidas |
| `/mvat diag` | Mostra o que o jogo escondeu no último combate (vida, recurso, auras) e o último erro capturado |

## Como ler o HUD

- **Borda colorida + rótulo em cima**: categoria (vermelho = emergência, laranja = interromper,
  roxo = dissipar, verde = cura, dourado = combo, azul = área, cinza = dano, ciano = buff).
- **Texto grande no canto do ícone**: sua tecla de atalho (ex.: `E`, `Shift+2`, `F1`).
  Se estiver vazio, a habilidade não está em nenhuma barra com atalho.
- **Texto abaixo**: o motivo da sugestão e o nome da habilidade.

## WoW Forever: valores secretos

O Forever usa o motor moderno do WoW, que esconde de addons várias informações durante o combate
("valores secretos": vida, recursos, auras, recargas…) e proíbe o log de combate. O MVAT:

- **não usa** o log de combate (evita o aviso "só disponível para a interface da Blizzard");
- checa cada valor antes de usar: o que vier secreto é tratado como "desconhecido" e a regra que
  dependia dele simplesmente não dispara — sem erros de Lua;
- regras do tipo "buff/DoT ausente" só aparecem quando o addon tem **certeza** de que ele está ausente;
- em combate, a fonte principal é o **brilho de proc da própria Blizzard**
  (`SPELL_ACTIVATION_OVERLAY_GLOW_SHOW`): quando uma habilidade acende (Sobrepujar, Executar,
  Revanche, procs de talento), o MVAT mostra o ícone dela com a sua tecla;
- quando o alvo inicia um cast, o aviso de interromper aparece mesmo se o nome do feitiço estiver oculto.

Por isso, em combate, as sugestões podem ser bem menos frequentes que fora dele. Use `/mvat diag`
depois de uma luta para ver o que o jogo liberou.

### Só o que está na sua barra

O MVAT lê as suas barras de ação (inclusive ElvUI/EllesmereUI, que usam os mesmos slots) e **só sugere
habilidades que você consegue apertar**. Com as barras vazias o filtro é ignorado. `/mvat barra` liga e
desliga. Habilidades de outros níveis só entram quando você as aprende (o livro de feitiços é relido).

### Paladino (regras do Forever)

O Forever tem um Paladino diferente do Classic Era, e o MVAT segue as notas de mudanças dos addons do próprio
Forever (TalentsForeverBook / WhatsTraining):

- **Selo escolhido pelo contexto**, entre os que você tem **e estão na barra**, com o motivo na tela:
  escudo equipado ou Fúria Justa ativa → **Selo da Fúria** ("o selo de tanque": dano Sagrado + absorção);
  arma lenta ou de duas mãos → **Comando** (a partir do nível 30); mana baixa → **Sabedoria**; caso
  contrário **Retidão**. O Cruzado só aparece se for o único que sobrou; a Justiça só com `/mvat selo justica`.
- **Antes da luta**, se o selo ativo não é o que o contexto pede, ele sugere trocar.
- **Julgamento não gasta mais o selo** (recarga de 10 s, alcance de 10 m; julgar a Fúria provoca o alvo): o
  MVAT não manda mais refazer o selo depois do Julgamento.
- **Golpe Sagrado** (recarga de 10 s), Exorcismo em morto-vivo/demônio, Consagração com vários inimigos,
  Fúria Justa quando há escudo, aura de Devoção (tanque) ou Retribuição (dano) e bênçãos.
- O estado do selo é rastreado pelos seus próprios casts e pela duração real vista nas auras, porque em
  combate o Forever esconde as auras.

### Outras classes (habilidades e regras do Forever)

Os IDs e as habilidades novas vêm da lista de treinador do próprio Forever (WhatsTraining/Camelot) e das notas
de mudanças (TalentsForeverBook). Cada classe usa o que existe no Forever:

| Classe | Habilidades do Forever usadas |
|---|---|
| Guerreiro | Investida (abertura), Vitória Rápida, Golpe Poderoso (15 s), Ira Sangrenta no início da luta, Temeridade em elite, Trovoada |
| Ladino | Abertura furtiva (Emboscada se tiver adaga; senão Golpe Baixo/Garrote), Esfaquear com adaga, Ruptura em elite |
| Mago | Arcane Blast (especialização Arcana), Ice Lance após Nova Congelante, Onda Explosiva |
| Sacerdote | Penance, Prayer of Mending, Shadow Word: Death (só com vida alta), Nova Sagrada |
| Caçador | Tiro Mirado/Múltiplo (recarga compartilhada), Contra-ataque |
| Bruxo | Bane da Agonia separado da Maldição, Dreno de Vida, Conflagrar, Fogo da Alma em elite |
| Xamã | Fire Nova (agora uma magia de 10 s), Corrente de Raios |
| Druida | Lacerar (urso), Pounce/Ravage (gato em Rondar) |

Em combate o Forever esconde **auras do alvo, Raiva/Energia e pontos de combo**. Para continuar sugerindo:

- **DoTs** (Dilacerar, Corrupção, Imolar, Fogo Lunar...) são rastreados pelo **tempo desde o seu último cast**
  (zera ao trocar de alvo); com auras legíveis, vale a aura real.
- **Pontos de combo** são contados pelos seus casts (cada gerador soma, cada finalizador zera).
- **Raiva/Energia desconhecidas**: o addon assume que há recurso (o jogo recusa se faltar).
- **Cura em combate** é limitada: a vida dos aliados é secreta, então curas por "vida baixa" só aparecem fora
  de combate; Prayer of Mending e afins aparecem por recarga.

### Painel de cast (o que o inimigo está castando)

O jogo não deixa um addon **ler** o nome do feitiço do inimigo em combate, mas deixa **mostrá-lo**
(`SetText`/`SetTexture` aceitam valor secreto) e controlar a transparência de um ícone por um
booleano secreto (`SetAlphaFromBoolean`). É a mesma técnica da barra de cast do EllesmereUI. Quando o
alvo castar, aparece um painel acima do ícone principal:

- **INIMIGO**: ícone e nome do que ele está castando (exibidos, nunca comparados);
- **INTERROMPER**: sua interrupção + tecla, só se ela existe e está fora de recarga (`isActive`);
  o ícone some sozinho se o cast **não** for interrompível;
- **DEFESA**: sua defesa + tecla, só aparece se o cast é **em você** e **não** é interrompível.

Por isso o addon **não** sabe *qual* feitiço é, e não escolhe a skill pelo nome dele. Escolhe pelo
*tipo* (interrompível, em você).

### Combos pela sua última skill

Os seus próprios casts continuam legíveis (`UNIT_SPELLCAST_SUCCEEDED` do jogador), então "usei A →
use B" funciona sem auras: Presença da Mente → Piroblasto, Selo → Julgamento, Corrupção → Imolar →
Seta Sombria, Marca → Picada → Tiro Arcano, Foco Interior → cura grande etc. Veja `SEQUENCES` em
`MVAT.lua`.

### Aviso do chefe

Se o cliente enviar `ENCOUNTER_WARNING` (o sistema que o DBM/BigWigs usam em Midnight), o MVAT mostra
o texto, o ícone e a severidade do aviso. `/mvat diag` informa se esse evento existe no seu cliente.

### Casts de outros inimigos (chefe, elites, quem mira em você)

O painel de cast principal olha o seu **alvo**. Como o DBM faz no Forever, o MVAT também escuta o cast
de qualquer inimigo (nameplates e `boss1-5`) e mostra, acima do painel principal, nome e ícone da
magia (valores secretos: só exibição) e o **alvo do cast**. Elite e chefe aparecem sempre; mob comum só
aparece quando o cast é **em você**. Se o cast em você não for interrompível, aparece o ícone da sua
defesa. O painel some quando o cast termina ou é interrompido. `/mvat casts` liga/desliga.

### LIMPAR: debuffs do grupo que você remove

Painel à esquerda do ícone principal, com você e o grupo/raide (até 4 linhas): quem está afetado, o
nome e o ícone do debuff e **a(s) sua(s) habilidade(s) de limpeza com a tecla**. Funciona em combate
com o filtro nativo `HARMFUL|RAID_PLAYER_DISPELLABLE` (o mesmo que ElvUI e EllesmereUI usam): o jogo
diz "este debuff você consegue remover" sem revelar o tipo. Quando o tipo está oculto e a sua classe
remove mais de um tipo, o painel mostra uma habilidade por tipo (no máximo 2). Jogadores fora de
alcance de dispel (`UnitInRange`) são ignorados. Classes sem dispel (Guerreiro, Ladino, Caçador,
Bruxo) não mostram o painel. `/mvat limpar` liga/desliga.

| Classe | Remove |
|---|---|
| Paladino | Veneno, Doença, Magia (Purificar / Expurgar) |
| Sacerdote | Magia (Dissipar), Doença (Abolir/Curar Doença) |
| Mago | Maldição (Remover Maldição Menor) |
| Xamã | Veneno, Doença (Curar Veneno / Doença) |
| Druida | Maldição, Veneno (Remover Maldição, Abolir/Curar Veneno) |

## Limitações conhecidas

- O painel LIMPAR depende de o cliente aceitar o filtro `RAID_PLAYER_DISPELLABLE`; `/mvat diag` mostra
  quantas leituras e quantos debuffs removíveis foram vistos, e o último erro.

- Habilidades de **pet** (Bloqueio de Feitiço do Caçador de Vil, Intimidação) não são sugeridas.
- O addon não sabe se você está **atrás** do alvo; Apunhalar/Retalhar só aparecem via proc.
- Curas apontam o aliado pelo nome no texto — o alvo da cura continua sendo escolha sua.
- Em clientes onde a API de casts de inimigos é limitada, o addon usa o combat log como reserva.

## Estrutura

```
MVAT/
  MVAT.toc   – metadados e SavedVariables
  MVAT.lua   – compatibilidade de API, spellbook, keybinds, contexto, regras por classe, motor e HUD
```

Para ajustar prioridades, edite as tabelas `CLASS_RULES.<CLASSE>` em `MVAT.lua`: as regras são
avaliadas de cima para baixo e a primeira válida é exibida.
