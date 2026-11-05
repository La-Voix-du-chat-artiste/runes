# Discovery — a good-view latent layer for the LFM3 suite

> **Source:** Randall Balestriero and Yann LeCun, *Proving and Improving the
> Platonic Representation Hypothesis with JEPAs*, arXiv:2610.39302v1,
> 29 October 2026. CC BY 4.0. Code: `galilai-group/prh-proof`.
> Read on 2026-11-02.
>
> **Status:** discovery. This note supersedes the GVS5H note that previously
> occupied this path. It does **not** replace
> `docs/LFM3_TEAM_DISCOVERY.md`; it adds a representation layer to the team
> design and says what that layer would change.
>
> **Companions:** `docs/LFM3_TEAM_DISCOVERY.md`,
> `docs/SMALL_MODEL_HARNESS_PRD.md`, `docs/SMALL_MODEL_HARNESS_PLAN.md`.
>
> **Scope:** a design analysis, not an implementation. Every number attributed
> to the paper is the paper's, not independently reproduced here. The paper is
> a population theory plus a set of small-scale alignment experiments; it is
> not a claim that a small model wins at open-ended generation.

---

## TL;DR

The paper's lever is **positive views**, not scale. A JEPA whose positive pairs
are two observations of one scene (*good views*) learns the world's
representation up to a rotation; a JEPA whose positives are corruptions of one
observation (*bad views*) spends capacity on its modality's nuisance. Next-token
prediction is a bad-view JEPA. That is why language models align with vision
mostly through scale, and why a 109M text JEPA can beat language models up to
72B on the paper's alignment benchmark.

The LFM3 suite should not try to be a 72B text model. It should be a
**multi-view sensor plus a small aligned latent layer**:

- `LFM3-VL-2B`, `LFM3-Audio-2B`, `LFM3-Omni-2B`, OCR/ASR and `d1` produce
  several **good views** of the same evidence state.
- A small bidirectional good-view encoder (33M–109M, the paper's recipe)
  aligns those views into one latent space up to a rotation. This is the JEPA.
- `d1` scores consistency and support; Ruby verifies anchors and budgets.
- `LFM3-1.7B` **decodes** the aligned evidence into prose. It is the captioner,
  not the reasoner and not the JEPA.

The bet is narrow and testable: on evidence-grounded, cross-modal work, good
views plus verification can match or beat a larger text-only LLM at a fraction
of the cost. On open-ended reasoning, coding and long-horizon planning, the
team should escalate. The paper does not support a broader claim, and neither
should we.

The sharpest finding for the current team is uncomfortable:

> `ideate A ‖ B` is not two views. It is two corruptions of one observation:
> same base model, same evidence, same prompt family. The paper predicts that
> this buys little unique information and shares nuisance. The current
> `proposal_collapse` check catches identical proposals, not shared blind spots.

The fix is to assign **different renderings of the same state** to A and B, or
to stop pretending there are two views and spend the call on verification.

---

## 1. What the paper actually claims

### 1.1 The theorem in one paragraph

Let a finite world have states `z` with distribution `p(z)`, and let `M`
modalities render it injectively as `x = g_m(z)`. A JEPA for modality `m`
minimises a prediction term over positive pairs plus an anti-collapse term:

```
L_m(f) = E_(z,z')~pi_m [ l(f(g_m(z)), f(g_m(z'))) ] + Omega(f)
```

If every modality shares the same positive-pair distribution `pi`, and the
minimiser is unique up to rotation, then every modality's encoder learns the
same world embedding `h*` up to one rotation:

```
f_m*(g_m(z)) = Q_m h*(z),   Q_m in O(k)
```

Any two modalities therefore agree up to the single rotation
`Q_m Q_m'^T`. The proof is short: each `f_m* ∘ g_m` minimises the same objective
on world states. The key assumption is uniqueness up to rotation, which the
paper proves for whitened spectral JEPAs under a spectral gap.

When the positive pairs differ, the paper bounds the misalignment by how much
the two positive-pair kernels differ and by the size of the spectral gap. When
the positives are corruptions of one observation, the encoder spends `r` of its
`k` directions on nuisance, and the alignment error is at least `2r`. That is
the formal content of "good views align, bad views do not".

### 1.2 Good views, bad views, and next-token prediction

| object | positives | what it learns | paper's evidence |
|---|---|---|---|
| **Good-view JEPA** | two observations of one scene, independent nuisances | the world's spectral embedding; nuisance-free | Flickr mutual 10-NN .062 vs .047 bad, .042 NTP; at scale .184 vs .088 and .111 |
| **Bad-view JEPA** | two corruptions of one observation, shared nuisance | the modality's nuisance, plus part of the scene | .047 on Flickr; .088 at scale |
| **Next-token prediction** | a prefix and its continuation in one document | wording, style and local co-occurrence; the document's nuisance | .042 on Flickr; .111 at scale |
| **Next-token on caption pairs** | two captions of one image, concatenated | still next-token; the pair barely helps | .043 vs .042 mutual 10-NN; R@1 .023 vs .021 |

Three details matter for Runes:

1. **Trimming is the knob that matters.** Views must keep only what two
   observations share. Whole captions as views lose about a quarter of the
   alignment (.185 vs .246 R@1). Masking, number of views, batch size, width and
   schedule move the mean by at most .016, about the seed spread. Gradient
   clipping prevents most collapses.
2. **Alignment lives in the leading spectral directions.** After the best
   rotation, image-text correlation is .70 on the first principal direction and
   decays to about .1 by the 60th. Low-variance directions need not align.
3. **The rotation is cheap.** One orthogonal map, fitted on `k` pairs in
   general position, composes separately trained encoders. The paper's captioner
   fits only that map on image-caption pairs and reaches CIDEr .838 on COCO
   with a text-only decoder.

### 1.3 The numbers that matter

These are the paper's numbers, on the paper's benchmarks. They are evidence for
a hypothesis, not a specification for Runes.

| claim | number | context |
|---|---|---|
| Good views need fewer samples | **42×** fewer samples, **14×** fewer text tokens, **435×** fewer unique images | same corpus and encoder; .109 vs .111 WIT at 21.6M vs 900M samples |
| A small text JEPA beats big LMs on alignment | **.184** vs Qwen2.5-72B **.154**, Llama-3-70B **.151**, CLIP text **.124**, MPNet **.118** | WIT-1024, DINOv2 ViT-B, mutual 10-NN |
| The lead holds on a second benchmark | COCO .161 vs Qwen 72B .108, Llama 70B .113, CLIP .132, MPNet .156 | COCO 5k test pairs |
| The lead holds with CLIP's image encoder | .230 vs Qwen 72B .210, Llama 70B .206 | WIT-1024, CLIP ViT-H/14 |
| Size and token budget | **109M** params, **116B** text tokens, **660×** smaller than 72B, **>100×** fewer tokens | the paper's headline comparison |
| A 33M encoder is already competitive | .125 on WIT at 50M images, level with Qwen2.5-3B/-7B (.125/.118) | trained on web text, no Flickr/COCO captions |
| Pair-free alignment is possible | FOSCTTM .018; CIFAR-10 86.0; CIFAR-100 67.2; ImageNet-100 64.4 | vs Qwen3-8B .018 / 83.4 / 61.7 / 47.6; NTP .287 / 25.5 / 19.9 / 20.3 |
| One rotation is a captioner | CIDEr .838 COCO, .519 Flickr | frozen DINOv2/DINOv3 + a Qwen2.5-1.5B text-only decoder, 32-sample consensus; only the rotation fitted on pairs |
| Alignment has a scaling law | RMSE .007 fit; .0093 prediction vs .0096 seed difference | 45-cell grid, 85 held-out runs; `q ∝ M^-0.30`, unique-image exponent `.19` |
| Compute is modest | mostly **1 GPU per run**; 8–16 GPUs for the 940M-image runs | BERT-S 33M, BERT-B 109M; 200 epochs on 145k captions; 800 epochs on MSR-VTT |

The most useful number for Runes is not the 42×. It is the **shape** of the
result: with the same data and the same encoder, changing only the positives
from bad to good moves alignment more than adding scale. That is a design
instruction, not a budget promise.

### 1.4 What the paper does not claim

| the paper says | what it does **not** say | consequence for Runes |
|---|---|---|
| A 109M text JEPA beats 72B LMs on **alignment** | that it beats them on QA, reasoning or generation | do not claim "small team beats big LLM" in general |
| Good views need 42× fewer samples on **one corpus/recipe** | that 42× transfers to every task | treat 42× as a hypothesis to test, not a constant |
| The theorem holds for **population optima, injective renderings, matched marginals** | that real, lossy modalities satisfy it | use it as a design guide; measure residual and gap |
| Good views require **knowing which texts describe the same scene** | that the grouping is free | the view contract and `state_id` are the hard part |
| On Recap, **two of three texts are model-generated recaptions** | that the gain is purely from human views | prefer independent renderings; label model-generated ones |
| Pair-free alignment works **with their method and hyperparameters** | that it is robust | use it as a fallback with a confidence gate |
| NTP is a bad-view JEPA **heuristically** | that it is a corollary of the theorem | say "predicts", not "proves", when talking about LMs |
| LeJEPA's full-distribution constraint is **assumed** unique up to rotation | that the proof covers it | do not overstate the guarantee |

The paper's own limitations section is unusually candid: no experiment meets the
theorem's hypotheses exactly, the image side mostly uses crops (bad views), and
the largest runs have one or three seeds. Runes should inherit that candour.

---

## 2. The uncomfortable implication for the current team

### 2.1 What the team already does right

The current design is already good-view hygiene at the prompt level:

- **Fresh contexts.** Every role sees one micro-task, not the transcript. That
  is trimming.
- **Distinct roles.** Perception, decision, prose and verification are separate
  contracts, not one model in a trench coat.
- **Typed decisions.** `d1` returns calibrated probabilities, not verbal
  confidence. That is a value head.
- **Verification instead of trust.** Ruby owns acceptance; a model's "done" is
  not evidence.
- **Decline is first-class.** A role can refuse outside its capacity, and the
  conductor can escalate.

Those are the right instincts. The paper explains why they help: they reduce
nuisance and keep each observation focused on the shared scene.

### 2.2 The bad-view problem

The current `answer-full` shape does this:

```
ideate A (direct)  ‖  ideate B (alternative)
        same base model, same evidence, same prompt family
```

The paper's definitions make the problem precise. A **good view** is two
observations of one world state with independent nuisances. A **bad view** is
two corruptions of one observation, which share the nuisance. Two prompts over
the same evidence are not two observations. They are two corruptions of the same
text rendering. They share:

- the same base model's blind spots and stylistic prior;
- the same evidence selection and the same omissions;
- the same language, formatting and retrieval errors;
- the same "direct vs alternative" instruction family.

The result is predictable: the proposals differ in wording, not in information.
The current `proposal_collapse` check catches identical proposals; it does not
catch **shared blind spots**. The `same-model-3x` control is the purest form of
this failure: three calls that cannot add a second observation. That is why it
is a control and never the candidate.

There are three honest fixes:

1. **Different renderings, same state.** Give A the OCR text and `d1` facts;
   give B the document image and the audio transcript. If the state has only
   one rendering, do not claim two views.
2. **Different trims, same state.** Give A the full evidence; give B a trimmed
   counter-evidence packet that keeps only the claims that could disconfirm A.
   This is a genuine view difference if the trims preserve the shared scene.
3. **One ideator, more verification.** If no second rendering exists, use one
   ideator and spend the second call on a `d1` judge or a Ruby counterexample
   search. More calls to the same view are not diversity.

This is the single most actionable change in this note. It does not require a
new model or a new schema. It requires the conductor to build a `ViewSet` and
assign views, not just roles.

This does not repeal the "distinct roles" rule; it sharpens it. Distinct roles
are necessary but not sufficient. Two contracted roles that read the same
rendering are still one observation. Until role LoRAs exist, the base model may
be the same, but the benchmark must label that arm `profile-only`, and the
same-view control (`same-model-3x`) must be reported next to it. A team that
cannot produce a second independent rendering should say so and use one
ideator, not manufacture diversity from a prompt.

### 2.3 The 1.7B is a decoder, not a reasoner

The paper's captioner is the right analogy. It trains a text-only decoder to
reconstruct a caption from a frozen text-JEPA embedding, adds Gaussian noise
matched to the rotation residual, and at inference applies the rotation to an
image embedding and decodes. The decoder never sees pixels. The rotation is the
only part fitted on pairs.

`LFM3-1.7B` can play the decoder role:

- it is the only model in the suite allowed to write prose;
- it is explicitly not recommended for complex multi-step reasoning or planning;
- it can consume a compact **latent card** or, later, a soft prompt from
  `LFM3-1.7B-Base`;
- it should never be asked to be the JEPA encoder. Its next-token training is
  exactly the bad-view objective the paper criticises.

The JEPA encoder should be a **small bidirectional model** trained with the
paper's recipe, not the causal 1.7B. A 33M BERT-S equivalent is enough to test
the idea; a 109M BERT-B equivalent is the paper's strong version. The LFM suite
supplies the views and the decoder; the small encoder supplies the alignment.
That division is more faithful to the paper than trying to turn the 1.7B into a
JEPA.

There is a weaker fallback: freeze the suite's features, whiten them, and fit a
rotation. That avoids a new encoder, but frozen causal features are anisotropic
and nuisance-heavy, and the ceiling is lower. It is the right first experiment,
not the final architecture.

### 2.4 What "better than a bigger LLM" can mean

The team can plausibly be better at:

- **cross-modal retrieval and grounding** — the answer depends on an image, a
  transcript and a typed fact agreeing;
- **nuisance invariance** — the answer should not change when the font, layout,
  language or phrasing changes;
- **contradiction detection** — two modalities disagree, and the team flags it
  instead of picking one;
- **calibrated decline** — the team knows when its evidence is insufficient;
- **cost per verified answer** — many cheap `d1` checks and one prose call.

The team will not be better at:

- open-ended reasoning, code, proofs, long-horizon planning;
- tasks with one clean text passage and no cross-modal signal;
- tasks where the big LLM's world knowledge is the main ingredient and the team
  has no retrieval;
- creative writing or anything that needs a single strong prior.

The benchmark must separate these. Pooling them into one "big-model parity"
number would be dishonest and would hide the only cases where the design wins.

### 2.5 Three ways to map the suite onto the paper

The question "can our 1.7B suite be used like their sub-1B JEPA?" has three
different answers depending on what "used like" means.

| mapping | what plays the JEPA | what the suite does | cost | verdict |
|---|---|---|---|---|
| **Suite as JEPA** | frozen LFM features + whitening + rotation | encodes and decodes | no new weights | weak but useful; J0 |
| **Suite as sensor + small JEPA** | a 33M–109M bidirectional good-view encoder trained on suite-generated views | produces views and decodes | one small training run | **faithful; J1** |
| **Suite as Base adapter** | `LFM3-1.7B-Base` adapted with a good-view / soft-prompt objective | everything | large, unproven | research only; not recommended |

If the question is "can `LFM3-1.7B` itself be the sub-1B JEPA?", the answer is
**no without retraining**. It is a causal next-token model; the paper's whole
point is that next-token positives are bad views. Its hidden states can be
frozen and whitened, but that is the weak mapping, not the paper's recipe.

If the question is "can the suite play the same role in the system?", the answer
is **yes**, with the division above: the suite is the multi-view sensor and the
prose decoder; a small bidirectional encoder is the JEPA; `d1` is the value
head; Ruby is the kernel. That is the mapping this note recommends.

---

## 3. Mapping the paper onto Runes

| paper | Runes |
|---|---|
| world state `z` | case state: the evidence packet plus the question's semantics |
| modality `m` | text, image, video, audio, typed `d1` facts |
| rendering `g_m(z)` | OCR text, caption, transcript, frame, `d1` answer |
| good view | two independent renderings of the same `state_id` |
| bad view | two chunks, crops, paraphrases or prompt variants of one rendering |
| nuisance `ν` | font, layout, language, style, compression, speaker, model voice |
| positive pair `π` | `pair.v1`: same `state_id`, different `rendering_sha256` |
| encoder `f_m` | small bidirectional good-view encoder (or frozen features + head) |
| rotation `Q` | `Alignment` matrix, fitted by orthogonal Procrustes |
| spectral gap `δ` | top-k eigenvalue gap of the positive-pair graph |
| anti-collapse `Ω` | whitening / SIGReg / variance-covariance regularisation |
| next-token prediction | `LFM3-1.7B`'s pretraining; not a good view |
| captioner | `LFM3-1.7B` decoder + latent card or soft prompt |
| pair-free alignment | optimal-transport fallback, confidence-gated |
| scaling law | `q` (fraction of good views) vs samples vs unique states |

### 3.1 World state and views

A `state_id` is the case id plus the hash of the evidence packet. A `View` is a
rendering of that state:

```json
{
  "state_id": "case:L1:sha256:...",
  "rendering_sha256": "...",
  "modality": "image",
  "source": "fixtures/invoice-07.png",
  "nuisance": ["font", "layout", "scan"],
  "trim": "region:412,88,980,140",
  "anchors": ["page:1", "box:412,88,980,140"]
}
```

A `ViewSet` is the collection of renderings available for a state. The conductor
builds it from the ledger; no model chooses it. A pair is **good** when:

- the two views share `state_id`;
- their `rendering_sha256` differ;
- they come from different modalities, capture times or independent sources;
- the trims preserve the shared scene;
- a `d1` pair validator says they are consistent.

A pair is **bad** when the renderings are the same bytes, the same document
chunk, the same prompt family, or the same model's paraphrase with no
independent observation. The `pair.v1` record is a ledger artifact, not a role
output.

### 3.2 Nuisance and trimming

The paper's most practical result is that **trimming matters most**. For Runes,
trimming is not a prompt hint; it is a contract:

- **Text:** strip headers, footers, boilerplate, navigation and duplicated
  captions; keep the span that answers the micro-task.
- **Image:** crop to the region of interest; keep the page or box anchor; drop
  the surrounding scan.
- **Audio:** keep the segment around the event; drop silence and filler.
- **Video:** keep the frames around the event; report the time range.
- **Typed facts:** keep the field and value; drop the explanation.

The pair's `shared_content_sha256` is the hash of the trimmed content both views
are supposed to share. If the two trims do not overlap on the scene, the pair is
not a good view. This is a mechanical check, not a judgment call.

Nuisance tags are recorded so the benchmark can probe invariance. A team that
changes its answer when the font changes, or when a paraphrase replaces a
literal caption, is leaking nuisance. That is a measurable failure.

### 3.3 Rotation and spectral gap

The `Alignment` object is deliberately small:

```ruby
alignment = Runes::Swarm::Alignment.load("config/alignments/vision-text.v1.json")
alignment.project(vector, modality: :image)   # -> shared-space vector
alignment.score(a, b)                          # -> cosine
alignment.stable?                              # -> residual, rank, gap
```

The matrix is fitted offline:

- paired embeddings `(x_i, y_i)` for the same `state_id`;
- centre and whiten each side;
- orthogonal Procrustes for equal dimensions; a linear map with orthonormal rows
  for unequal dimensions;
- report `residual`, `rank`, `spectral_gap`, `pairs`, `seed`, `fit_sha256`.

The runtime only does dot products. No heavy linear-algebra dependency enters
the kernel. The matrix is JSON, hash-pinned in the receipt and, when a role
requires it, in the manifest next to `adapter_sha256`. This is the same
discipline as an adapter hash.

`stable?` is the gate:

```
residual <= max_residual
rank >= min_rank
spectral_gap >= min_gap
pairs >= min_pairs
```

If any condition fails, the conductor must not make a cross-modal claim. It
falls back to the unimodal path, declines `alignment_unstable`, or escalates.
A small spectral gap means the top-k directions are not separated from the
rest; the paper's bound says alignment is then unstable. That is exactly the
kind of failure a small model should refuse, not guess through.

### 3.4 The decoder

Three stages, in increasing cost:

**v0 — latent card (no training).** Project the evidence into the shared space,
take the top anchors by cosine to the question, add modality, score and
contradiction flags, and write a compact text block:

```
LATENT CARD
state: case:L1
question cosine: 0.81
anchors: page:1 box:412,88,980,140 (image), span:12-18 (ocr)
agreement: image/ocr 0.93; d1 support 0.88
conflicts: none
```

The answerer receives the card plus the trimmed evidence. This is auditable and
requires no new weights. It is the right first step.

**v1 — soft prompt on Base.** Train a small adapter on `LFM3-1.7B-Base` to
reconstruct text from the aligned latent, with Gaussian noise matched to the
residual cosine:

```
sigma = sqrt(c^-2 - 1)
```

where `c` is the mean cosine after rotation. The paper uses `c ≈ .3`, `sigma ≈ 3`.
The adapter is hash-pinned, and only the Base checkpoint may carry it. This is
the paper's captioner recipe adapted to the suite.

**v2 — latent planner.** Train an action-conditioned predictor on the aligned
space and search a few steps before decoding. This is research, not production.
The paper explicitly says its analysis does not cover learned predictors or
actions. Treat it as a separate spike with a synthetic task first.

### 3.5 `d1` as value head and pair validator

`d1` already owns calibrated scores for support, contradiction, coverage and
sufficiency. The new use is a **pair consistency** question:

> Given two renderings of the same claimed state, do they describe the same
> state? Return a calibrated yes/no and the fields that disagree.

This is cheap (the card reports ~6 ms per decision), so it can validate every
pair before the team uses it. It also gives the benchmark a gold-independent
view-quality signal. The calibration bands still apply: if support is low or
contradiction is high, the pair is rejected, not averaged.

`d1` is not an encoder. It reads typed answers from one forward pass; it does
not expose a reliable embedding. Use it as a scorer, not as the JEPA.

### 3.6 Ruby as the kernel enforcer

The conductor owns the view assignment, the alignment choice and the gate. The
model never chooses its own view, just as it never chooses its own identity.
The verifier checks:

- every anchor resolves to a real page/box/time/frame;
- the alignment is stable for the modalities in use;
- the pair is good, not a corruption;
- the latent card's scores match the stored alignment;
- the nuisance probe did not change the answer beyond the threshold.

The ledger stores `views.json`, `pairs.json`, `alignment.json`, `latent.json`,
`latent_card.md` and `nuisance_probe.json`. The receipt records the alignment
id, residual, rank, gap, view kind and nuisance delta. This is the same
"publish hashes, not raw prompts" discipline as the existing receipts.

---

## 4. Three designs

### 4.1 Proposal A — frozen good-view index (J0)

**What it is.** No training. Use frozen features from the suite (VL/Audio/Omni
for media, a mean-pooled 1.7B hidden state or a small sentence encoder for
text), whiten, and fit a rotation on a small paired calibration set. Build a
latent index over the evidence. Use it for retrieval, cross-modal consistency
and candidate reranking.

**Strengths.**

- Ships in days; no new weights; no training pipeline.
- Fits the existing contract: one more artifact, one more gate, no new role.
- Auditable: the matrix, the pairs and the residual are all in the receipt.
- Immediately useful even if the JEPA thesis fails: it is a better retrieval
  index.

**Weaknesses.**

- Frozen causal features are anisotropic and carry nuisance; the paper's
  theory assumes a whitened JEPA, not a causal LM's last hidden state.
- No latent planning; the 1.7B still does all the prose.
- The calibration set is the bottleneck: `k` pairs in general position, and
  `k` can be 384–1024.

**Acceptance.** Residual < 0.25, rank ≥ 32, a retrieval gain over text-only on
the latent suite, nuisance delta < 5%, no regressions on the 24-case pilot.

### 4.2 Proposal B — trained good-view heads (J1)

**What it is.** Freeze the suite's perception models; train a small
bidirectional encoder (33M–109M) with the paper's recipe on trimmed views:
2 global + 6 local views, 50–100% / 15–50% spans, 15% mask, LeJEPA/SIGReg with
λ = 0.02, batch 256, 200 epochs, gradient clipping, three seeds. Fit the
rotation on a held-out paired set. Export the encoder and the matrix.

**Strengths.**

- The faithful version of the paper: good views, small encoder, rotation.
- The encoder can beat frozen features because it is trained to ignore nuisance.
- Still small: 33M is ~2% of the 1.7B; 109M is ~6%.
- The paper's recipe is public and the compute is modest (one GPU per run for
  the small scales).

**Weaknesses.**

- Needs paired data and a training pipeline (Python/MLX or PyTorch).
- Collapse risk; the paper reports abrupt collapses without clipping.
- The encoder is a new artifact to version, hash and ship.
- The gain may not transfer from alignment to task pass; that is the central
  risk.

**Acceptance.** Residual < 0.15, `team-latent-j1` ≥ `team-latent-j0` + 2 cases,
zero regressions, cost ≤ 2× J0, consistent across three seeds.

### 4.3 Proposal C — latent planner (J2)

**What it is.** Train an action-conditioned predictor on the aligned space:

```
s_t = encoder(evidence_t)
s_(t+1) = predictor(s_t, a_t)     # a_t in {retrieve, perceive, ask_d1, repair}
value(s_t) = d1(s_t, question)
```

At inference, search a few steps in latent space, score with `d1`, decode only
the winning trajectory with the 1.7B.

**Strengths.**

- The real JEPA-as-world-model; could cut calls and improve multi-step tasks.
- The 1.7B never has to plan; the search is explicit and inspectable.

**Weaknesses.**

- No action-labelled data; the predictor would be trained on synthetic or
  logged trajectories, with sparse reward.
- Compounding error; a bad latent step is hard to detect.
- The paper explicitly does not cover learned predictors or actions.
- Verification is harder: a latent trajectory is not an executable test.

**Recommendation.** A research spike after J1, on a synthetic task with known
dynamics, then a two-step retrieval task. It must beat a greedy policy at equal
calls before it touches production. Do not put it on the critical path.

### 4.4 Decision matrix

| criterion | J0 frozen index | J1 trained heads | J2 latent planner |
|---|---|---|---|
| time to first result | days | weeks | months |
| new weights | none | 33M–109M | predictor + heads |
| faithfulness to paper | partial | high | extrapolation |
| risk | low | medium | high |
| can ship behind a flag | yes | yes, after benchmark | no |
| main failure | anisotropic features | collapse / no transfer | compounding error |
| recommendation | **ship first** | **benchmark-gated spike** | **research only** |

The hybrid is: J0 now, J1 if the benchmark says alignment transfers, J2 only
if J1 produces a stable latent space and a synthetic planner beats greedy.

---

## 5. The recommended architecture

### 5.1 Data flow

```
task + evidence
  │
  ├─ ViewSet (Ruby)             state_id, renderings, nuisance, trim, anchors
  ├─ d1 pair validator          good / bad / conflict, calibrated
  ├─ Alignment (J0 or J1)       project to shared latent, residual, gap
  ├─ Latent index               retrieve, cluster, contradiction candidates
  │
  ├─ conductor                  select shape + views + alignment
  │
  ├─ ideate A ‖ B               A and B see different views, not different prompts
  ├─ d1 judge                   support / coverage / risk / choice
  ├─ answerer (1.7B)            latent card + trimmed evidence -> answer.v1
  ├─ test (Ruby)                mechanical checks, non-blocking
  ├─ review (d1 + Ruby)         claim support + repair instructions
  ├─ repair (1.7B, once)        bounded
  ├─ verify (Ruby)              anchors, alignment, nuisance probe, tests
  │
  └─ receipt                    views, pairs, alignment, latent, calibration
```

The loop is the existing memdoor loop with two new checkpoints (`views`,
`align`) and one new decode input (the latent card). It is not a new runtime.

### 5.2 The loop with latent checks

| step | what happens | gate |
|---|---|---|
| `intake` | `d1` triage detects modality and shape | `call`, `decision` |
| `views` | Ruby builds the `ViewSet`; `d1` validates pairs | `provenance`, `view` |
| `plan` | Ruby writes the micro-step DAG and view assignment | `schema`, `budget` |
| `align` | load/fit the alignment; project evidence; compute residual/gap | `alignment` |
| `perceive` | VL/Audio/Omni produce `perception.v1` for their views | `modality`, `provenance` |
| `ideate` | A and B see different views of the same state | `view` |
| `judge` | `d1` scores support, coverage, risk, choice | `calibration` |
| `answer` | 1.7B receives the latent card + trimmed evidence | `schema` |
| `test` | Ruby runs mechanical checks | `verifier` |
| `review` | `d1` + Ruby write `review.v1` | `calibration` |
| `repair` | one bounded round | `progress` |
| `verify` | rerun checks + alignment + nuisance probe | `verifier`, `alignment` |
| `receipt` | hashes, scores, costs, cold/warm | `route` |

The order is the existing one with `alignment` inserted after `provenance` if
J1 ships. For J0, fold the alignment checks into `provenance` and `calibration`
so the 14-gate contract does not change before the benchmark justifies it.

### 5.3 New artifacts and schemas

| artifact | file | schema | producer |
|---|---|---|---|
| views | `views.json` | `view.v1` (array) | Ruby |
| pairs | `pairs.json` | `pair.v1` (ledger-only) | Ruby + `d1` |
| alignment | `alignment.json` | metadata + matrix ref | Ruby / offline fit |
| latent | `latent.json` | `latent.v1` (array) | Ruby |
| latent card | `latent_card.md` | text | Ruby |
| nuisance probe | `nuisance_probe.json` | `probe.v1` (ledger-only) | Ruby |

`view.v1`:

```json
{
  "state_id": "case:L1:sha256:...",
  "rendering_sha256": "...",
  "modality": "image",
  "source": "fixtures/invoice-07.png",
  "nuisance": ["font", "layout", "scan"],
  "trim": "region:412,88,980,140",
  "anchors": ["page:1", "box:412,88,980,140"]
}
```

`latent.v1`:

```json
{
  "state_id": "case:L1:sha256:...",
  "modality": "image",
  "alignment_id": "align.vision-text.v1",
  "vector_ref": "sha256:...",
  "dims": 384,
  "rank": 64,
  "residual": 0.18,
  "anchors": ["page:1", "box:412,88,980,140"]
}
```

The vector itself stays in a content-addressed store; the ledger keeps its
reference and the receipt records its hash, not the numbers. This keeps
receipts publishable.

`view.v1` and `latent.v1` are role-facing schemas and join
`Capacity::SCHEMAS` when a role emits them. By contrast, `pair.v1` and
`probe.v1` are ledger records produced by Ruby; they do not join the role
schema allow-list unless a model is later contracted to emit them. Keeping the
two sets separate avoids widening the model contract for data the harness
already owns.

### 5.4 Gates and decline reasons

For J0, no new gate is required:

- `provenance` also checks that every view has a resolvable anchor and that the
  pair's `shared_content_sha256` is non-empty.
- `calibration` also checks `residual`, `rank` and `spectral_gap` against the
  alignment's thresholds.

For J1, promote `alignment` to its own gate:

```
call → envelope → identity → capacity → decision → body → schema
     → modality → provenance → alignment → verifier → calibration
     → progress → budget → route
```

New decline reasons, added only when the corresponding check ships:

| reason | when |
|---|---|
| `alignment_unstable` | residual, rank or spectral gap outside the threshold |
| `view_conflict` | `d1` says two renderings of one state disagree |
| `nuisance_leak` | the nuisance probe changes the answer beyond the threshold |
| `latent_missing` | the shape requires a latent but none was produced |

These are routing decisions, not errors. A decline is recorded and the
conductor falls back to a unimodal path or escalates.

### 5.5 File map

| path | purpose |
|---|---|
| `lib/runes/swarm/view.rb` | `View`, `ViewSet`, good/bad pair validation |
| `lib/runes/swarm/alignment.rb` | load/project/score/stable?; matrix metadata |
| `lib/runes/swarm/latent.rb` | `Latent` value object; vector refs; rank/residual |
| `lib/runes/swarm/latent_card.rb` | compact, anchor-preserving card |
| `lib/runes/swarm/nuisance_probe.rb` | deterministic probe harness |
| `config/alignments/*.json` | matrix, dims, fit stats, hash |
| `bench/latent/embed.py` | extract frozen features from the suite |
| `bench/latent/views.py` | build trimmed views, masks, pairs |
| `bench/latent/fit.py` | whiten + Procrustes / LeJEPA head |
| `bench/latent/evaluate.py` | mutual 10-NN, R@1, residual, gap |
| `bench/swarm/latent_cases.json` | the 8-case latent suite |
| `bench/swarm/runner.rb` | extend arms and metrics |
| `test/swarm_view_test.rb` | good/bad pair rules |
| `test/swarm_alignment_test.rb` | fit/project/stable? on synthetic rotations |
| `test/swarm_latent_test.rb` | card shape, hash, no raw vector |
| `test/swarm_alignment_gate_test.rb` | broker/guard declines |
| `test/swarm_nuisance_probe_test.rb` | invariance and leak detection |

### 5.6 What does not change

- The seven rune verbs. This is library classes plus a benchmark.
- The contract/conductor design. The model still never owns the plan.
- The 14-gate order for J0. `alignment` is promoted only if J1 ships.
- The 24-case pilot. The latent suite is a separate 8-case addendum, not a
  replacement.
- The rule that same-model arms are controls, never candidates.
- The rule that `discovery.md` and `docs/2609.20804v1.pdf` are untracked.
- No runtime dependency on `runes-lang/glyphes/tmp`.
- No use of `docs/epics/` or `docs/missions/`.

---

## 6. How it could beat a bigger LLM

### 6.1 Four mechanisms

**1. Nuisance-invariant evidence.** A text-only big LLM sees one rendering. The
team sees the image, the OCR, the transcript and the typed facts, trims each to
the shared scene, and aligns them. If the answer depends on the scene rather
than the wording, the team's representation is closer to the world state. The
paper's Flickr and WIT results are evidence that this is not just more data: the
same encoder with good views beats bad views and NTP.

**2. Cross-modal contradiction.** The team can detect that the video says "two
people" and the transcript says "three", or that the invoice image and the OCR
disagree on a total. A text-only LLM cannot see the conflict unless someone
wrote it into the prompt. The aligned space plus `d1` gives a calibrated
contradiction score; the verifier turns it into a decline or a targeted repair.

**3. Cheap calibrated search.** `d1` can score many candidates in milliseconds.
The team can retrieve, rerank, ask a judge, and only then spend the 1.7B on the
winning candidate. A big LLM spends its tokens on one shot. This is a
cost/latency advantage, not an IQ advantage, and the benchmark should report it
as such.

**4. Verification instead of self-report.** The 1.7B's answer is checked by
Ruby anchors, `d1` support and executable tests. A big LLM's confidence is not a
verification signal. On cases where the big LLM is confidently wrong and the
team declines or repairs, the team wins on **reliability**, not on knowledge.

### 6.2 What it will not beat

- Open-ended reasoning, code, proofs, long-horizon planning.
- A single clean text passage with no cross-modal signal; here the big LLM's
  scale is a real advantage.
- Tasks where the big LLM's parametric knowledge is the main ingredient and the
  team has no retrieval.
- Creative writing, style transfer, anything that needs one strong prior.
- Cases where the views are model-generated paraphrases with shared nuisance;
  the paper's own ablation shows the gain shrinks when the views are not
  independent.

### 6.3 The claim in one sentence

> On evidence-grounded tasks whose answer depends on cross-modal consistency or
> nuisance-invariant retrieval, a good-view LFM3 team can match or beat a larger
> text-only LLM at a fraction of the cost, and it declines when its views or
> alignment are insufficient.

That is the only claim the paper supports. Anything broader is marketing.

### 6.4 Falsification

The idea should be killed if any of these is true:

- A sweep over `q` (the fraction of good-view pairs) does not increase task
  pass; the view contract is then not doing the work.
- Alignment residual improves but downstream task pass does not; representation
  alignment is not the bottleneck.
- The nuisance probe changes answers under font, layout, language or paraphrase
  changes beyond the threshold; the team is still leaking nuisance.
- The `d1` pair validator disagrees with gold on a substantial fraction; the
  view contract is unreliable.
- `same-model-3x` or `bad-view-2x` matches `good-view-2x`; the gain is just more
  calls.
- The cost per verified answer exceeds the big LLM's by more than the agreed
  factor; the design is not economically interesting.
- The big LLM wins on the same cases with the same evidence; the claim is false
  for that family.

---

## 7. Benchmark addendum

The 24-case pilot stays as it is. This is a separate **`swarm-latent`** suite of
8 cases, run only when J0 or J1 is under test. It is tracked, repo-local, and
never reads `runes-lang/glyphes/tmp`.

### 7.1 The 8 cases

| id | family | what it tests | gold |
|---|---|---|---|
| `L1` | cross-modal retrieval | invoice image + OCR; answer the total | total + `page:1` + `box` |
| `L2` | nuisance invariance | same document, two fonts/layouts; answer must not change | same answer, same anchors |
| `L3` | paraphrase invariance | same evidence, two phrasings; answer must not change | same answer |
| `L4` | cross-modal contradiction | video says two people, transcript says three | flag conflict, do not pick one |
| `L5` | audio-visual grounding | speech refers to an object; ground it in the frame | object + `frame`/`time` |
| `L6` | view conflict | OCR and image disagree on a number | decline or escalate |
| `L7` | pair-free alignment | no paired calibration; OT fallback | within a stated degradation |
| `L8` | latent rerank | two candidate answers; pick the supported one | supported candidate + anchor |

Each case carries `state_id`, `views` (at least two where the case claims a
good-view pair), `gold`, `checks`, `expected_shape`, `expected_decision` and
`forbidden_roles`. A case that cannot supply two independent renderings is a
**single-view** case and must not be counted as evidence for the good-view
claim.

### 7.2 Arms

| arm | what it is | role |
|---|---|---|
| `solo-1.7B` | one text call | text baseline |
| `team-full` | the existing 24-case team shape | composition baseline |
| `team-latent-j0` | team + frozen index + rotation | J0 candidate |
| `team-latent-j1` | team + trained heads + rotation | J1 candidate |
| `frontier-1x` | external big LLM, same evidence | gap reference |
| `same-model-3x` | three 1.7B calls, same view | control |
| `bad-view-2x` | two chunks/paraphrases of one rendering | control |
| `good-view-2x` | two independent renderings | treatment |

Ablations on `L1`, `L4`, `L7`, `L8` only:

| arm | what it removes | expected result |
|---|---|---|
| `no-rotation` | shared space without Procrustes | worse |
| `random-rotation` | a random orthogonal map | much worse |
| `pair-free` | OT alignment instead of paired fit | within a stated gap |

### 7.3 Metrics

- **Task pass:** all checks pass, including the expected decision.
- **Alignment:** mutual 10-NN, R@1, residual, rank, spectral gap.
- **Nuisance delta:** answer and latent change under font, layout, language and
  paraphrase transforms. Report per transform, not pooled.
- **Contradiction detection:** precision/recall on `L4` and `L6`.
- **View quality:** good/bad classification accuracy vs gold; `d1` validator
  calibration (ECE, Brier).
- **Selection quality:** chosen proposal's pass rate vs best/worst available.
- **Decline/escalation:** precision/recall; over-decline rate on answerable
  cases.
- **Cost:** calls by model/role, tokens, wall time, cold/warm, peak memory.
- **Gap closure:** `(team - baseline) / (frontier - baseline)` per family; `n/a`
  when the denominator is zero or negative.
- **q sweep:** task pass vs the fraction of good-view pairs, with `q ∈ {0, 0.1,
  0.3, 1.0}` on a subset. `q` is varied by swapping good pairs for bad pairs of
  the same state, holding the case and evidence fixed. This is the direct test
  of the paper's scaling law: if pass does not rise with `q`, the view contract
  is not doing the work.

### 7.4 Controls that can kill the idea

| control | if it wins | what it means |
|---|---|---|
| `bad-view-2x` beats `good-view-2x` | the view contract is wrong or the task does not depend on the scene | stop, fix the contract |
| `same-model-3x` matches `team-latent` | the gain is more calls, not better views | stop, do not ship |
| `no-rotation` matches the aligned arm | the rotation is not doing work | stop, use the raw space |
| `random-rotation` matches the aligned arm | the metric is insensitive | stop, fix the metric |
| `pair-free` is far worse | OT is not robust enough | keep it as a fallback only |
| `frontier-1x` wins on every case | the claim is false for this suite | report it, do not spin it |

### 7.5 Go/no-go

**J0 GO** if all of:

- residual < 0.25, rank ≥ 32, spectral gap above the fitted threshold;
- `team-latent-j0` ≥ `team-full` + 1 case on `L1`–`L8`;
- zero regressions on cases `team-full` passed;
- nuisance delta < 5% on `L2`/`L3`;
- cost ≤ 1.5× `team-full`.

**J1 GO** if all of:

- residual < 0.15, rank ≥ 64;
- `team-latent-j1` ≥ `team-latent-j0` + 2 cases;
- zero regressions;
- cost ≤ 2× J0;
- the gain is consistent across three seeds.

**J2 GO** only if:

- a synthetic dynamics task shows the predictor beats a greedy policy at equal
  calls;
- a two-step retrieval task shows the same;
- the latent trajectory can be verified mechanically.

If any control wins, stop and document the negative result. A negative result is
still a useful discovery; a spun positive is not.

---

## 8. Implementation plan

### 8.1 J0 — frozen index (ship first)

1. `Runes::Swarm::View` and `ViewSet`: `state_id`, `rendering_sha256`,
   `modality`, `nuisance`, `trim`, `anchors`; good/bad pair rules; tests.
2. `Runes::Swarm::Alignment`: load a JSON matrix; `project`, `score`, `stable?`;
   synthetic-rotation tests; unequal-dimension test; fewer-than-`k`-pairs test.
3. `Runes::Swarm::Latent` and `LatentCard`: vector ref, rank, residual,
   anchors; no raw vector in the card; hash-pinned.
4. Ledger artifacts: `views.json`, `pairs.json`, `alignment.json`,
   `latent.json`, `latent_card.md`, `nuisance_probe.json`.
5. `d1` pair-validator prompt: use the existing `judge` role; no new role.
6. `bench/latent/embed.py`: extract frozen features for the 8 cases.
7. `bench/latent/fit.py`: whiten + Procrustes; export the matrix and stats.
8. `bench/latent/evaluate.py`: mutual 10-NN, R@1, residual, gap.
9. `bench/swarm/latent_cases.json` + runner arms.
10. Receipt fields: `alignment_id`, `residual`, `rank`, `spectral_gap`,
    `view_kind`, `nuisance_delta`, `latent_sha`.

### 8.2 J1 — trained heads (benchmark-gated)

1. `bench/latent/views.py`: 2 global + 6 local views; 50–100% / 15–50% spans;
   15% mask; nuisance tags; deterministic seeds.
2. `bench/latent/fit.py`: LeJEPA/SIGReg head; gradient clipping; three seeds;
   collapse detection (effective rank, loss).
3. Export `config/alignments/*.json` and the head hash.
4. Ruby loads the head metadata; the actual forward pass stays in the Python
   sidecar, not the kernel.
5. Benchmark `team-latent-j1` against J0 and `team-full`.
6. If GO, update the PRD/PLAN; if NO-GO, keep J0 and write the negative result.

### 8.3 J2 — latent planner (research spike)

1. Synthetic world with known dynamics and a small action set.
2. Action-conditioned predictor; `d1` value head; 1–3 step search.
3. Compare against greedy at equal calls.
4. Two-step retrieval task.
5. Stop if either fails. Do not touch production.

### 8.4 Tests to write first

| test | what it proves |
|---|---|
| `test/swarm_view_test.rb` | same state/different rendering is good; same bytes or same nuisance is bad; missing anchor is invalid |
| `test/swarm_alignment_test.rb` | a synthetic rotation is recovered; residual and gap are reported; unequal dims work; `< k` pairs is underdetermined |
| `test/swarm_latent_test.rb` | the card keeps anchors; the vector is hashed, not printed; rank/residual are present |
| `test/swarm_alignment_gate_test.rb` | the broker declines `alignment_unstable`; the guard flags a bad pair; a stable pair passes |
| `test/swarm_nuisance_probe_test.rb` | a font/paraphrase change does not change the answer; a scene change does |
| `test/swarm_latent_bench_test.rb` | the 8 cases run with fake models; no network; no tmp |

All of these are fake-driven. No live provider calls, no GPU, no network.

### 8.5 Commit sequence

1. `swarm: add view and alignment contracts` — `View`, `ViewSet`, `Alignment`,
   tests, fixtures.
2. `swarm: add latent card and ledger artifacts` — `Latent`, `LatentCard`,
   ledger files, receipt fields.
3. `swarm: add alignment checks to broker and guard` — staged behind J0,
   promoted to a gate only for J1.
4. `bench: add swarm-latent suite and arms` — 8 cases, runner, metrics.
5. `bench: add good-view fitting scripts` — J1 only, if the benchmark says GO.
6. `docs: add the JEPA addendum` — update PRD/PLAN; keep `discovery.md`
   untracked.

Do not commit `discovery.md` or `docs/2609.20804v1.pdf`.

---

## 9. Failure modes and mitigations

| failure | why it happens | mitigation |
|---|---|---|
| Frozen features are anisotropic | causal LM hidden states are not LeJEPA embeddings | whiten; use a small bidirectional head; measure effective rank |
| Rotation is unstable | small spectral gap or too few pairs | `stable?` gate; more pairs; decline `alignment_unstable` |
| Views share nuisance | same model, same prompt, same chunk | independent renderings; `d1` validator; label model-generated views |
| No second view exists | text-only case with one passage | one ideator; spend the call on verification; do not fake diversity |
| Alignment improves, task does not | representation is not the bottleneck | downstream probe; stop J1; keep J0 as an index |
| Latent card is too lossy | top-k projection drops the answer | keep anchors and raw evidence; add a soft prompt only if needed |
| `d1` pair validator is miscalibrated | distribution shift | calibrate on a separate set; Ruby anchors as a backstop |
| Cost or latency grows | many views and alignment calls | cache; batch; run the latent path only on cross-modal cases |
| Privacy leak | latent vectors encode evidence | store locally; hash in receipts; redact raw text |
| Overclaim | alignment is not generation | scoped claim; separate text and multimodal; report `n/a` |
| Collapse in J1 | no clipping or bad SIGReg weight | gradient clipping; three seeds; effective-rank check |
| Pair-free alignment fails | initialization | confidence gate; paired fallback; do not default to it |

---

## 10. Open questions

1. Are `LFM3-1.7B` hidden states a useful text encoder after whitening, or do we
   need a small bidirectional model trained from scratch?
2. How many paired examples are needed for a stable rotation at 384, 768 and
   1024 dimensions? The paper says `k` pairs in general position; real data may
   need more.
3. Is `d1`'s typed space a useful view, or is it too lossy to align? It is
   calibrated, but it is not an embedding.
4. Can `LFM3-Omni-2B`'s joint audio-video representation replace separate
   VL/Audio alignment, or is it a weaker, non-reasoning view?
5. How should time alignment work for video and audio? A frame anchor and a
   transcript span are not the same object.
6. What is the right trimming policy per modality, and can it be mechanical
   enough for the verifier?
7. Can we generate good views without a captioner, so the views do not inherit a
   model's nuisance? The paper's alt-text + paraphrase ablation suggests yes,
   but weaker.
8. Does the paper's 42× sample efficiency hold for Runes' small paired sets, or
   is it an artifact of the Recap corpus?
9. How do we benchmark nuisance invariance without gold latents? The probe is a
   proxy; it needs its own validation.
10. Can a latent planner be verified mechanically, or is it inherently a
    research artifact?

---

## 11. Sources

| source | what to read it for |
|---|---|
| <https://arxiv.org/html/2610.39302v1> | the full paper: theorem, bounds, experiments, appendices |
| <https://arxiv.org/abs/2610.39302v1> | abstract and metadata |
| `galilai-group/prh-proof` | the paper's code; not copied here |
| [LiquidAI/LFM3-1.7B](https://huggingface.co/LiquidAI/LFM3-1.7B) | text model card; no complex planning |
| [LiquidAI/LFM3-1.7B-Base](https://huggingface.co/LiquidAI/LFM3-1.7B-Base) | adapter substrate; requires an adapter hash |
| [LiquidAI/LFM3-VL-2B](https://huggingface.co/LiquidAI/LFM3-VL-2B) | image/video/document perception |
| [LiquidAI/LFM3-Audio-2B](https://huggingface.co/LiquidAI/LFM3-Audio-2B) | ASR, speech translation, audio events |
| [LiquidAI/LFM3-Omni-2B](https://huggingface.co/LiquidAI/LFM3-Omni-2B) | joint audio-video perception; non-reasoning |
| [LiquidAI/d1-2B](https://huggingface.co/LiquidAI/d1-2B) | calibrated typed decisions; ~6 ms |
| [LiquidAI/d1-Omni-2B](https://huggingface.co/LiquidAI/d1-Omni-2B) | audio triage; weaker on text |
| `docs/LFM3_TEAM_DISCOVERY.md` | the team, roster, shapes, loop, gates |
| `docs/SMALL_MODEL_HARNESS_PRD.md` | the 24-case pilot, metrics, go/no-go |
| `docs/SMALL_MODEL_HARNESS_PLAN.md` | the implementation phases |

**Citation:** Balestriero, R. and LeCun, Y. *Proving and Improving the Platonic
Representation Hypothesis with JEPAs.* arXiv:2610.39302v1, 29 October 2026.
CC BY 4.0. The paper's code is separate; if any of it is adapted, carry its
license and attribution. The analysis here is Runes' own.

---

## Appendix A — paper numbers used in this note

| quantity | value | where it comes from |
|---|---|---|
| Good-view Flickr mutual 10-NN | .062 ± .003 | Table 1 |
| Bad-view Flickr mutual 10-NN | .047 ± .001 | Table 1 |
| Next-token Flickr mutual 10-NN | .042 ± .001 | Table 1 |
| Good-view Flickr R@1 | .044 ± .002 | Table 1 |
| Bad-view Flickr R@1 | .027 ± .002 | Table 1 |
| Next-token Flickr R@1 | .021 ± .002 | Table 1 |
| Good-view WIT mutual 10-NN | .184 | Table 3 |
| Next-token WIT mutual 10-NN | .111 | Table 3 |
| Bad-view WIT mutual 10-NN | .088 | Table 3 |
| Qwen2.5-72B WIT | .154 | Table 3 |
| Llama-3-70B WIT | .151 | Table 3 |
| CLIP B/32 text WIT | .124 | Table 3 |
| MPNet WIT | .118 | Table 3 |
| Good-view COCO | .161 | Table 3 |
| Qwen2.5-72B COCO | .108 | Table 3 |
| Llama-3-70B COCO | .113 | Table 3 |
| CLIP B/32 text COCO | .132 | Table 3 |
| MPNet COCO | .156 | Table 3 |
| Good-view CLIP-H | .230 | Table 3 |
| Qwen2.5-72B CLIP-H | .210 | Table 3 |
| Llama-3-70B CLIP-H | .206 | Table 3 |
| Good-view Flickr R@1 at scale | .478 | Table 3 |
| Next-token Flickr R@1 at scale | .335 | Table 3 |
| Bad-view Flickr R@1 at scale | .318 | Table 3 |
| CLIP B/32 text Flickr R@1 | .489 | Table 3 |
| MPNet Flickr R@1 | .481 | Table 3 |
| 42× fewer samples | 21.6M vs 900M | §4.2 |
| 14× fewer text tokens | 3 texts per sample | §4.2 |
| 435× fewer unique images | 2.16M vs 940M | §4.2 |
| 109M params, 116B tokens | 660× smaller than 72B, >100× fewer tokens | §4.3 |
| 33M WIT at 50M images | .125 | §4.1 |
| Pair-free FOSCTTM | .018 | Table 4 |
| Pair-free CIFAR-10 | 86.0 | Table 4 |
| Pair-free CIFAR-100 | 67.2 | Table 4 |
| Pair-free ImageNet-100 | 64.4 | Table 4 |
| Qwen3-8B pair-free | .018 / 83.4 / 61.7 / 47.6 | Table 4 |
| NTP pair-free | .287 / 25.5 / 19.9 / 20.3 | Table 4 |
| Captioner COCO CIDEr | .838 | §5.1 |
| Captioner Flickr CIDEr | .519 | §5.1 |
| Trimming loss | .185 vs .246 R@1 | §3.2 |
| Scaling-law RMSE | .007 fit, .0093 prediction, .0096 seed | §4.4 |
| `q ∝ M^-0.30` | iso-alignment | §4.4 |
| Unique-image exponent | .19 | §4.4 |
| Compute | 1 GPU most runs; 8–16 for 940M | Appendix B |

---

## Appendix B — glossary

| term | meaning in this note |
|---|---|
| **JEPA** | Joint-Embedding Predictive Architecture: predict in representation space, not pixel/token space |
| **good view** | two observations of one world state with independent nuisances |
| **bad view** | two corruptions of one observation, sharing its nuisance |
| **nuisance** | modality-specific variation that is irrelevant to the world state: font, style, viewpoint, wording |
| **positive pair** | the pair a JEPA is trained to bring together |
| **spectral embedding** | the top eigenvectors of the positive-pair graph; the JEPA's population solution |
| **rotation** | the orthogonal map that relates two modalities' embeddings |
| **Procrustes** | the least-squares orthogonal map between two paired point clouds |
| **spectral gap** | the gap between the k-th and (k+1)-th eigenvalues; large gap means stable alignment |
| **SIGReg** | LeJEPA's isotropic-Gaussian regulariser; an anti-collapse term |
| **LeJEPA** | a JEPA recipe that uses SIGReg as its anti-collapse term |
| **mutual 10-NN** | fraction of 10-nearest-neighbour sets shared by two spaces; chance is 10/N |
| **R@1** | retrieval recall at 1 after one rotation |
| **FOSCTTM** | fraction of samples closer than the true match; 0 is perfect, .5 is chance |
| **CIDEr** | captioning metric; the paper reports it on a 0–1 scale |
| **WIT** | the PRH paper's Wikipedia image-text benchmark |
| **Recap-DataComp** | web image-text corpus with alt-text and recaptions |
| **latent card** | a compact, anchor-preserving text summary of an aligned latent |
| **view contract** | the `view.v1` / `pair.v1` rules that decide good vs bad views |
