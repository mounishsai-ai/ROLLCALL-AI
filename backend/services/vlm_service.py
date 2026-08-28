"""
The system's second opinion: a vision model that looks at faces the local
embedding model could not settle.

Two questions can be asked of it. `verify_match()` is the narrow one — "are
these two photos the same person?" — and only ever confirms or vetoes a guess
that has already been made. `identify_among_candidates()` is the open one —
"which of these students is this, if any?" — and is what allows a wrong guess
to be corrected rather than merely doubted.

Both answer in three states, never two. A call that fails is not a rejection,
and an unreadable reply is not evidence that somebody is a stranger. Collapsing
either into a "no" marks real students absent for reasons that never appear in
any log.

Transport: Vertex AI when a Google Cloud project is configured, otherwise the
AI Studio API key. This is worth the branch. On the AI Studio free tier the
strongest model was measured returning "503 high demand" for minutes on end;
through Vertex on a billed project the same model answered in 3.5 seconds.
"""

import json
import os
import re
import threading
import time

from google import genai
from google.genai import types

# Candidates are shown to Gemini as lettered options rather than by
# registration number. Reg numbers here are short digits ("1".."12"), and a
# model asked to "reply with the number" tends to conflate them with counting
# ("the 2nd photo"). Letters remove that ambiguity entirely.
_CANDIDATE_LABELS = "ABCDEFGH"


class VLMVerificationService:
    """Asks a vision model about faces the local model is unsure of."""

    def __init__(self):
        self.timeout_seconds = float(os.getenv("VLM_TIMEOUT_SECONDS", "20"))
        # Identification sends the query face plus several registration photos,
        # so it is a heavier request than the two-image yes/no check and gets
        # its own budget.
        self.identify_timeout_seconds = float(os.getenv("VLM_IDENTIFY_TIMEOUT_SECONDS", "30"))

        self.model_name = os.getenv("VLM_MODEL_NAME", "gemini-3.7-flash")
        # Preferred model first, then progressively lighter stand-ins. Even on
        # Vertex a model can be briefly unavailable, and a demo should degrade
        # to a faster model rather than fail.
        fallbacks = os.getenv("VLM_FALLBACK_MODELS", "gemini-3.5-flash,gemini-3.1-flash-lite")
        self.model_chain = [self.model_name] + [
            m.strip() for m in fallbacks.split(",") if m.strip() and m.strip() != self.model_name
        ]
        # Once a model has failed, every later face in the same scan would hit
        # the same wall and burn the whole timeout again. Remember the failure
        # for a while and skip straight to one that works.
        self.unhealthy_cooldown = float(os.getenv("VLM_UNHEALTHY_COOLDOWN_SECONDS", "120"))
        self._unhealthy: dict[str, float] = {}
        self._lock = threading.Lock()

        self._client = None
        self.transport = "none"
        self.is_configured = False
        self._configure_client()

        if self.is_configured:
            print(
                f"[OK] VLM service ready via {self.transport}. "
                f"Model chain: {' -> '.join(self.model_chain)}"
            )
            # The first call on a fresh process pays a one-time connection and
            # model warm-up cost, which would otherwise land on the first live
            # demo request. Warm it in the background so startup isn't blocked.
            threading.Thread(target=self._warm_up, daemon=True).start()

    # ──────────────────────────────────────────────
    #  Transport
    # ──────────────────────────────────────────────

    def _configure_client(self):
        """
        Prefer Vertex AI, fall back to an AI Studio key, tolerate neither.

        Vertex is tried first because it is the one with real quota behind it.
        The API-key path is kept rather than deleted so the system still runs
        for anyone who has a key but no Cloud project.
        """
        project = os.getenv("VERTEX_PROJECT") or os.getenv("GOOGLE_CLOUD_PROJECT")
        location = os.getenv("VERTEX_LOCATION", "global")

        if project:
            try:
                self._client = genai.Client(vertexai=True, project=project, location=location)
                self.transport = f"Vertex AI ({project}/{location})"
                self.is_configured = True
                return
            except Exception as e:
                print(f"[WARN] Vertex AI client could not be created ({e}); falling back to API key.")

        api_key = os.getenv("GEMINI_API_KEY")
        if api_key:
            try:
                self._client = genai.Client(api_key=api_key)
                self.transport = "AI Studio API key"
                self.is_configured = True
                return
            except Exception as e:
                print(f"[WARN] AI Studio client could not be created: {e}")

        print("[WARN] No Gemini credentials found (set VERTEX_PROJECT or GEMINI_API_KEY). Second opinions are disabled.")

    def _is_healthy(self, name: str) -> bool:
        with self._lock:
            return time.time() >= self._unhealthy.get(name, 0.0)

    def _mark_unhealthy(self, name: str):
        with self._lock:
            self._unhealthy[name] = time.time() + self.unhealthy_cooldown

    def _generate(self, contents, timeout: float) -> tuple[str, str]:
        """
        Run one request against the model chain, returning (text, model_used).

        Tries each model in order, skipping any that failed recently, and
        raises only once every model has been tried. That way the callers'
        "error" state means "nothing could answer this", not "the first thing I
        tried was busy".
        """
        chain = [m for m in self.model_chain if self._is_healthy(m)]
        if not chain:
            # Everything is cooling down; the preferred model is worth one more
            # attempt rather than refusing outright.
            chain = [self.model_chain[0]]

        config = types.GenerateContentConfig(
            http_options=types.HttpOptions(timeout=int(timeout * 1000))
        )

        errors = []
        for name in chain:
            try:
                response = self._client.models.generate_content(
                    model=name, contents=contents, config=config
                )
                return (response.text or "").strip(), name
            except Exception as e:
                self._mark_unhealthy(name)
                errors.append(f"{name}: {e}")
                print(f"[WARN] Gemini model '{name}' unavailable ({type(e).__name__}); trying next in chain.")

        raise RuntimeError(" | ".join(errors) if errors else "No Gemini model available.")

    def _warm_up(self):
        try:
            _text, model_used = self._generate("Reply with OK.", timeout=self.timeout_seconds * 3)
            print(f"[OK] VLM warm-up completed on '{model_used}'; connection is ready.")
        except Exception as e:
            print(f"[WARN] VLM warm-up failed on every model (will retry on first real request): {e}")

    @staticmethod
    def _image(data: bytes):
        return types.Part.from_bytes(data=data, mime_type="image/jpeg")

    # ──────────────────────────────────────────────
    #  Closed question: is this the person we think?
    # ──────────────────────────────────────────────

    def verify_match(self, known_face_bytes: bytes, group_face_bytes: bytes) -> str:
        """
        Compares two face images.

        Returns:
            "yes"   - the same person.
            "no"    - not the same person.
            "error" - the call failed (timeout, network, bad credentials).
                      Must NOT be treated the same as "no" by callers.
        """
        if not self.is_configured:
            print("[WARN] VLM verification skipped because no credentials are configured.")
            return "error"

        try:
            prompt = (
                "You are an expert facial recognition investigator. "
                "Are these two photos of the exact same person? "
                "Consider lighting, angles, and facial structure carefully. "
                "Reply with only YES or NO."
            )
            raw, model_used = self._generate(
                [prompt, self._image(known_face_bytes), self._image(group_face_bytes)],
                timeout=self.timeout_seconds,
            )
            result = raw.upper()
            print(f"[VLM] Gemini response ({model_used}): {result}")
            return "yes" if "YES" in result else "no"

        except Exception as e:
            print(f"[ERROR] VLM Verification failed: {e}")
            return "error"

    # ──────────────────────────────────────────────
    #  Open question: which of these people is this?
    # ──────────────────────────────────────────────

    def identify_among_candidates(
        self,
        query_face_bytes: bytes,
        candidates: list[tuple[str, str, bytes]],
    ) -> dict:
        """
        Shows one unidentified face plus several candidate students and asks
        which one it is — or whether it is none of them.

        This is strictly more capable than verify_match(): verify_match() can
        only confirm or veto a guess the vector search already made, so a wrong
        top-1 stays wrong. Here the model can pick a different candidate, which
        is what lets the system *correct* the local model rather than only doubt it.

        Args:
            query_face_bytes: JPEG of the unidentified face from the group photo.
            candidates: list of (reg_number, name, jpeg_bytes) registration photos.

        Returns:
            {"decision": reg_number | "none" | "error",
             "confidence": "high"|"medium"|"low"|None,
             "reason": str,
             "model_used": str (present on success)}

        "none" is a real, meaningful answer — the face belongs to somebody not
        enrolled in this class. It must never be collapsed into "error", and
        "error" must never be reported as "none": one is a finding, the other
        is a failure to reach a finding.
        """
        if not self.is_configured:
            return {"decision": "error", "confidence": None, "reason": "No Gemini credentials are configured."}

        if not candidates:
            return {"decision": "error", "confidence": None, "reason": "No candidates supplied."}

        candidates = candidates[: len(_CANDIDATE_LABELS)]
        label_to_reg = {_CANDIDATE_LABELS[i]: c[0] for i, c in enumerate(candidates)}
        roster = ", ".join(
            f"{_CANDIDATE_LABELS[i]} = {name}" for i, (_reg, name, _b) in enumerate(candidates)
        )

        prompt = (
            "You are verifying classroom attendance from a group photo.\n\n"
            "The FIRST image is one unidentified face cropped from the group photo. "
            f"The following {len(candidates)} images are enrolled students, in order: {roster}.\n\n"
            "Decide which enrolled student the first face is, if any. Compare face shape, "
            "eye spacing, nose and jaw structure, and any distinctive permanent features. "
            "Ignore lighting, blur, expression, camera angle, hairstyle and accessories — "
            "these differ between a registration photo and a classroom photo.\n\n"
            "IMPORTANT: the person in the first image may not be any of the students shown. "
            "If no candidate is genuinely the same person, answer NONE. Do not force a match — "
            "wrongly marking a visitor as a student is worse than leaving the face unresolved.\n\n"
            "Reply with ONLY this JSON, no markdown:\n"
            '{"match": "<letter or NONE>", "confidence": "high|medium|low", '
            '"reason": "<one short sentence a teacher would understand>"}'
        )

        contents = [prompt, self._image(query_face_bytes)]
        for _reg, _name, img_bytes in candidates:
            contents.append(self._image(img_bytes))

        try:
            raw, model_used = self._generate(contents, timeout=self.identify_timeout_seconds)
        except Exception as e:
            print(f"[ERROR] VLM identification failed on every model: {e}")
            return {"decision": "error", "confidence": None, "reason": f"Gemini call failed: {e}"}

        result = self._parse_identification(raw, label_to_reg)
        result["model_used"] = model_used
        return result

    @staticmethod
    def _parse_identification(raw: str, label_to_reg: dict[str, str]) -> dict:
        """
        Turns the model's reply into a decision. Kept separate and pure so it
        can be tested against malformed replies without spending a call.

        A reply that cannot be parsed is reported as "error", never as "none" —
        an unreadable answer is not evidence that the person is a stranger.
        """
        # Models sometimes wrap JSON in ```json fences despite being told not to.
        cleaned = re.sub(r"^```(?:json)?|```$", "", raw.strip(), flags=re.MULTILINE).strip()

        match_value, confidence, reason = None, None, ""
        try:
            data = json.loads(cleaned)
            match_value = str(data.get("match", "")).strip()
            confidence = str(data.get("confidence", "")).strip().lower() or None
            reason = str(data.get("reason", "")).strip()
        except Exception:
            # Fall back to pulling a bare letter or NONE out of free text.
            if re.search(r"\bNONE\b", cleaned, re.IGNORECASE):
                match_value = "NONE"
            else:
                letter = re.search(r"\b([A-H])\b", cleaned)
                match_value = letter.group(1) if letter else None
            reason = cleaned[:200]

        if not match_value:
            return {"decision": "error", "confidence": None, "reason": f"Could not read Gemini's reply: {raw[:120]}"}

        upper = match_value.upper()
        if upper == "NONE":
            return {"decision": "none", "confidence": confidence, "reason": reason or "Not any of the enrolled students shown."}

        reg_number = label_to_reg.get(upper[:1])
        if reg_number is None:
            return {"decision": "error", "confidence": None, "reason": f"Gemini named an unknown option '{match_value}'."}

        return {"decision": reg_number, "confidence": confidence, "reason": reason or "Facial structure matches."}
