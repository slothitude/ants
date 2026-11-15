# Ant Colonies → Multi-Agent Console: Research Brief

Research on how real ant colonies organise thousands of ants, mapped to the
NecroMancer console's soul-pool design. Gathered 2026-11-14 via a research
lane; every fact is tied to its source. This is the design input for the
Orchestrator milestone (per-soul controls, telemetry, task allocation).

## 1. Colony-level organisation

Ant colonies are caste systems — workers, soldiers, foragers, nurses, and
reproductives (queen + winged alates) ([Wikipedia: Ant](https://en.wikipedia.org/wiki/Ant)). Two allocation mechanisms coexist: **caste polyethism** (fixed morphological specialists) and **age polyethism** (the same worker changes jobs as she ages — young ants nurse indoors, old ants forage outside) ([Iwasa 2020, PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC7039887)). The dominant allocation model is **response thresholds** (Bonabeau/Theraulaz/Deneubourg; reinforced-threshold models are the field's workhorse, ~629 citations): each ant carries internal thresholds per task; a task's stimulus strength (crumbs piling up, larvae screaming) crossing an ant's threshold makes *that* ant act. Ants are set off by their genes, age, experience and body size ([Yamanaka 2019](https://pubmed.ncbi.nlm.nih.gov/30526909)). Gordon's key reallocation finding: colonies adjust *how many* ants do each task with no central control, and young small colonies show nest-maintenance workers switching to foraging under demand while old large ones don't — the switching rule itself scales ([Gordon 2016 review](https://link.springer.com/article/10.1007/s00265-015-2045-3)).

**Mapping:** each soul type = a caste with per-task-class thresholds; the
orchestrator never micromanages — it just pumps a task-stimulus into the
blackboard and lets souls self-assign when their threshold trips. Age
polyethism = soul seniority: a fresh soul starts on cheap tasks, earns
foraging depth.

## 2. Communication

Trails are chemical gradients: Argentine ant recruitment pheromone is
(Z)-9-hexadecenal, deposited from the sternal gland, distinct from a
persistent hindgut "home-plane" marker ([Heyman 2017, PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC6476803)). Half-lives differ by species and job: Argentine recruitment trails die in ~10–15 min (a 60-min abandonment kills recruitment to 32%), fire ants ~30–50 min, *Atta* leafcutters 1–2 days, *Formica* 2–4 days — short trails track ephemeral food, long trails mark stable territory ([van Wilgenburg 2012, *Current Biology*](https://www.cell.com/current-biology/fulltext/S0960-9822(12)00352-0); [Wikipedia: Ant communication](https://en.wikipedia.org/wiki/Ant)). **Tandem running** in *Temnothorax* is pairwise teaching: one scout leads one follower by touch, and it meets the biological definition of teaching ([Basari 2014](https://pubmed.ncbi.nlm.nih.gov/24903681)). **Antennation** — seconds-long antennal contact — is the message channel. The **anternet** (Gordon + Prabhakar, Stanford): returning-forager rate functions exactly like TCP ACKs; quick successful returns push more foragers out, slow empty returns throttle the pipeline — rate-based congestion control with no spatial information, "essentially the same as TCP" ([Stanford Engineering](https://engineering.stanford.edu/news/stanford-biologist-and-computer-scientist-discover-anternet)).

**Mapping:** blackboard entries carry TTLs in two classes — short-lived
"trail" entries (task offers, partial results, minutes) and long-lived
"territory" entries (project conventions, codebase facts). Tandem running =
the orchestrator walking one sub-ant to its task context before spawning the
rest.

## 3. Scaling

Harvester colonies range ~50 ants (young) to ~10,000 (mature), and *behavior changes with size*: older, larger colonies are more stable and consistent in response to perturbation, because more ants means encounters are more frequent and decisions ride on **interaction rate, not interaction content** ([Gordon 2024, Proc. R. Soc. B](https://pmc.ncbi.nlm.nih.gov/articles/PMC11528356); [Gordon 2016](https://link.springer.com/article/10.1007/s00265-015-2045-3)). No ant knows colony size; each runs local rules, and "some aspects of network behavior just depend on size" ([Gordon interview](https://www.edge.org/conversation/deborah_gordon-decoding-the-remarkable-algorithms-of-ants)). Evolution then acts on colony-level strategies: colonies that restrain foraging in bad conditions produce more offspring ([Gordon 2013, Nature](https://pubmed.ncbi.nlm.nih.gov/23676676)).

**Mapping:** don't hardcode per-colony orchestration logic that assumes 13
souls vs 130. Keep the per-soul interaction budget constant
(encounters-per-minute ACK rate), and scale emerges: a bigger pool just
reaches decisions with fewer interactions per ant.

## 4. Swarm intelligence formalisms

**ACO** (Dorigo 1991 thesis; Dorigo & Stützle, MIT Press) is the formalism:
artificial ants construct solutions probabilistically weighted by τ
(pheromone = learned) times η (heuristic, e.g. 1/distance = hard-coded) with
the transition rule τ^α·η^β; evaporation factor ρ ∈ (0,1] decays trails each
iteration to prevent premature convergence and stale routes ([Wikipedia:
ACO](https://en.wikipedia.org/wiki/Ant_colony_optimization_algorithms); [ACO
book PDF](https://web2.qatar.cmu.edu/~gdicaro/15382/additional/aco-book.pdf)).
**Stigmergy** (Grassé's term) is the substrate: agents modify the environment
and later agents read the environment, never each other ([Dorigo 2000, "Ant
algorithms and stigmergy"](https://link.springer.com/article/10.1007/978-3-7091-6245-1_5)). ACO succeeds on combinatorial graph problems (TSP, routing,
scheduling) where solutions are paths and credit is local. It fails when the
objective isn't path-structured, when credit assignment is ambiguous, or when
pheromone bounds aren't tuned (hence MAX–MIN AS's explicit τmin/τmax caps).
Contrast: PSO/ABC explore continuous/global objective spaces; ACO's edge is
discrete combinatorics.

**Mapping:** stigmergy is the console's core contract — souls never message
each other directly; they write to the shared environment only. Evaporation =
context decay, and the τmin/τmax lesson says clamp your blackboard scores.

## 5. Failure handling

**Dead ants:** necrophoresis — corpses are detected by the loss of "life"
chemical cues (dolichodial/iridomyrmecin) and carried to midden piles; corpse
removal measurably raises colony survival ([Diez 2014, PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC4126623)). When disease risk is high, corpses are carried *farther* and dropped at distance — triaged disposal ([Royal Society Open Science 2024](https://royalsocietypublishing.org/rsos/article/11/12/240764/92460/Social-organization-of-necrophoresis-insights-into)). **Lost trails:** ants keep redundant state — path integration plus visual memories, with a systematic search pattern when everything fails ([Heyman 2019, PMC](https://pmc.ncbi.nlm.nih.gov/articles/PMC6476803)); individual memory alone can even re-find food after the trail has decayed ([van Wilgenburg 2012](https://www.cell.com/current-biology/fulltext/S0960-9822(12)00352-0)). **Trapped/lost ants** are simply not retried — the colony reallocates, one ant is cheap. **Raiding:** slave-maker ants scout a host nest, then recruit raiders along a trail to steal brood; host colonies fight back with nest defense and **enemy specification** — learning the raider's specific odor and rejecting it forever ([Wikipedia: Slave-making ant](https://en.wikipedia.org/wiki/Slave-making_ant); [Foitzik 2001](https://pubmed.ncbi.nlm.nih.gov/11308089) — ~50% raid rate/yr in some populations).

**Mapping:** reap/heal = necrophoresis, not resurrection — a failed soul is
quarantined (removed from the pool) and its task context marked poisoned
rather than retried in place. Lost trail = the soul falls back to its own
private memory before re-exploring. Enemy specification = quarantine the
*fingerprint* of poisoned input (a bad doc, an injected prompt), so no soul
ever follows that trail again.

## 6. Mapping summary (one line each)

| Mechanism | Console mapping |
|---|---|
| Patroller-sets-direction | Orchestrator polls first; gates sub-ant launches on return-rate |
| 3-at-a-time batches | Tandem-run-sized recruit waves; depth cap = bounded interaction radius (1+3+9) |
| Two-class pheromone TTLs | Blackboard: short-lived task trails + long-lived territory facts |
| Response thresholds per caste | Per-soul-type thresholds; souls self-assign, orchestrator only raises stimulus |
| TCP/anternet ACK rate | Launch-rate throttle: fast successful returns → open window; slow → back off |
| Necrophoresis | Reap: quarantine failed souls, drop their context into the midden |
| Redundant navigation | Souls keep private memory as fallback when shared context decays |
| Evaporation + τmin/τmax | Decay task context on a TTL; clamp scores to force re-exploration |
| Enemy specification | Quarantine fingerprints of poisoned/injected content, permanently |

**Design headline:** the whole organism runs on one invariant —
communication is environment-mediated, rate-based, and decaying. No
soul-to-soul direct messaging anywhere in the stack.
