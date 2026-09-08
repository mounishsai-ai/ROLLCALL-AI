"""
The Adjudicator: the part of the system that decides what to do about a face
it is not sure about.

The recognition pipeline (detect -> embed -> search -> threshold) always runs
the same steps in the same order and answers every face with a number. That is
fine when the number is decisive and useless when it is not, which is exactly
the case attendance keeps producing: a face turned away from the camera, a
student in the back row 40 pixels wide, two siblings in the same class.

This module handles those faces one at a time. For each, it looks at what it
actually has (how big, how sharp, how close the runner-up was), picks a tool it
thinks will resolve *that* face, runs it, and looks again. Cheap local tools are
tried before expensive remote ones, and a face that resolves early costs nothing
more. Every observation, choice and outcome is emitted as it happens, so the
reasoning can be watched rather than inferred from the final answer.

Two properties are deliberate and worth not breaking:

- Everything is keyed by `face_id`, never by student. Two faces in one photo can
  produce the same top-1 guess, and identity-keyed state merges them into one.
- "Not any of these students" is a real verdict, separate from "the check
  failed". An open room contains people who are not on the roster, and the
  system has to be able to say so rather than pinning a stranger on whoever
  scored highest.
"""

import base64
import concurrent.futures
import os
import threading
import time

import cv2
import numpy as np

# Every re-crop is detected at exactly this size, whatever the face's real
# dimensions were.
#
# This is not cosmetic. RetinaFace runs on TensorFlow, which builds a graph per
# input shape: feeding it a differently-sized image each time pays a fresh
# graph build, measured at tens of seconds per shape. Sending one fixed canvas
# means the cost is paid once for the whole process — and can be paid up front
# by the startup warm-up instead of during a scan.
RESCAN_CANVAS_PX = int(os.getenv("ADJ_RESCAN_CANVAS_PX", "384"))


def letterbox(img: np.ndarray, size: int) -> np.ndarray:
    """
    Fit an image onto a fixed square canvas without distorting it.

    Stretching to a square would change the proportions of the face, which is
    exactly the information the embedding model reads, so the image is scaled
    to fit and the leftover space is padded.
    """
    h, w = img.shape[:2]
    if h == 0 or w == 0:
        return np.zeros((size, size, 3), dtype=np.uint8)

    scale = size / max(h, w)
    new_w, new_h = max(1, int(round(w * scale))), max(1, int(round(h * scale)))
    interpolation = cv2.INTER_CUBIC if scale > 1 else cv2.INTER_AREA
    resized = cv2.resize(img, (new_w, new_h), interpolation=interpolation)

    canvas = np.zeros((size, size, 3), dtype=img.dtype)
    top, left = (size - new_h) // 2, (size - new_w) // 2
    canvas[top:top + new_h, left:left + new_w] = resized
    return canvas


class AttendanceAdjudicator:
    """Investigates uncertain faces from one group photo."""

    def __init__(self, face_service, emit=None):
        self.svc = face_service
        self._emit_fn = emit
        self._emit_lock = threading.Lock()
        self._started_at = time.time()
        # The budget covers the investigation, not the detection that precedes
        # it. Detection is work that has to happen no matter what; on a cold
        # process it alone can take over a minute, and charging that to the
        # budget leaves nothing for the investigations the budget exists to
        # bound — every face gets skipped for "no time left" before a single
        # tool has run. Set for real once the first pass is done.
        self._budget_starts_at = self._started_at

        # How many uncertain faces are worth investigating at all. Faces are
        # investigated best-score-first, so the cap drops the least promising.
        self.max_investigations = int(os.getenv("ADJ_MAX_INVESTIGATIONS", "8"))
        # Total wall clock the investigation phase may consume. Gemini answers
        # in roughly 7-13s warm; without a ceiling, a photo full of hard faces
        # turns a demo into a three-minute wait even though nothing is broken.
        self.time_budget = float(os.getenv("ADJ_TIME_BUDGET_SECONDS", "120"))
        # A face narrower than this many pixels is worth re-cropping before
        # anyone looks at it, human or model.
        self.min_face_px = int(os.getenv("ADJ_MIN_FACE_PX", "90"))
        # Variance of the Laplacian, the standard cheap sharpness measure.
        # Low variance means few edges means blur.
        self.blur_threshold = float(os.getenv("ADJ_BLUR_THRESHOLD", "60"))
        self.max_workers = int(os.getenv("VLM_MAX_WORKERS", "5"))
        # How many students are worth putting in front of a vision model at
        # once. Every extra photo costs latency on an already-heavy multimodal
        # request, and adds one more way to answer wrongly.
        self.shortlist_max = int(os.getenv("ADJ_SHORTLIST_MAX", "4"))
        # A neighbour scoring far below the leader is noise, not a rival. Only
        # candidates within this fraction of the top score are real contenders.
        self.shortlist_ratio = float(os.getenv("ADJ_SHORTLIST_RATIO", "0.65"))

    # ──────────────────────────────────────────────
    #  Trace emission
    # ──────────────────────────────────────────────

    def _emit(self, kind: str, title: str, **fields):
        """Publish one step of the reasoning trace."""
        event = {
            "ts": round(time.time() - self._started_at, 2),
            "kind": kind,
            "title": title,
            "face_id": fields.pop("face_id", None),
            "detail": fields.pop("detail", ""),
            "tool": fields.pop("tool", None),
            "thumb": fields.pop("thumb", None),
        }
        event.update(fields)
        if self._emit_fn:
            with self._emit_lock:
                self._emit_fn(event)

        label = f"face {event['face_id']}" if event["face_id"] is not None else "scan"
        line = f"[ADJ {event['ts']:6.2f}s] ({label}) {title}" + (f" - {event['detail']}" if event["detail"] else "")
        try:
            print(line)
        except UnicodeEncodeError:
            # A Windows console defaults to cp1252, which cannot encode the
            # arrows and dashes this trace uses. Logging must never be able to
            # take down an investigation, so fall back to a lossy line instead
            # of letting the exception escape.
            print(line.encode("ascii", "replace").decode("ascii"))

    def _time_left(self) -> float:
        return self.time_budget - (time.time() - self._budget_starts_at)

    # ──────────────────────────────────────────────
    #  Image helpers
    # ──────────────────────────────────────────────

    @staticmethod
    def _crop_from(img: np.ndarray, area: dict, pad: float) -> np.ndarray:
        """Cut a padded face box out of a full-size photo, clamped to bounds."""
        x, y = int(area.get("x", 0)), int(area.get("y", 0))
        w, h = int(area.get("w", 0)), int(area.get("h", 0))
        if w <= 0 or h <= 0:
            return img
        pad_w, pad_h = int(w * pad), int(h * pad)
        y1, y2 = max(0, y - pad_h), min(img.shape[0], y + h + pad_h)
        x1, x2 = max(0, x - pad_w), min(img.shape[1], x + w + pad_w)
        crop = img[y1:y2, x1:x2]
        return crop if crop.size else img

    @staticmethod
    def _to_jpeg(img: np.ndarray, max_width: int, quality: int) -> bytes:
        """Encode a BGR image as JPEG, downscaling only if it is wider than max_width."""
        if img.shape[1] > max_width:
            scale = max_width / img.shape[1]
            img = cv2.resize(img, (max_width, max(1, int(img.shape[0] * scale))), interpolation=cv2.INTER_AREA)
        ok, buf = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
        return buf.tobytes() if ok else b""

    def _thumb(self, img: np.ndarray) -> str:
        """Small base64 JPEG so the UI can show the face being discussed."""
        data = self._to_jpeg(img, max_width=160, quality=72)
        return base64.b64encode(data).decode("ascii") if data else ""

    def _assess_quality(self, crop: np.ndarray, area: dict, detector_confidence: float) -> dict:
        """
        Cheap local look at a face before spending anything on it.

        This is what makes the tool choice a decision rather than a fixed order:
        a small, soft face is worth re-cropping, and a large sharp one that is
        still ambiguous is a genuine identity question that only a second
        opinion can settle.
        """
        face_w = int(area.get("w", crop.shape[1]))
        face_h = int(area.get("h", crop.shape[0]))
        gray = cv2.cvtColor(crop, cv2.COLOR_BGR2GRAY) if crop.ndim == 3 else crop
        blur_score = float(cv2.Laplacian(gray, cv2.CV_64F).var())

        is_small = face_w < self.min_face_px
        is_blurry = blur_score < self.blur_threshold

        if is_small and is_blurry:
            summary = f"small and soft — {face_w}x{face_h}px, sharpness {blur_score:.0f}"
        elif is_small:
            summary = f"small — only {face_w}x{face_h}px in the photo"
        elif is_blurry:
            summary = f"out of focus — sharpness {blur_score:.0f}"
        else:
            summary = f"good quality — {face_w}x{face_h}px, sharpness {blur_score:.0f}"

        return {
            "face_w": face_w,
            "face_h": face_h,
            "blur_score": round(blur_score, 1),
            "detector_confidence": round(float(detector_confidence), 3),
            "is_small": is_small,
            "is_blurry": is_blurry,
            "summary": summary,
        }

    # ──────────────────────────────────────────────
    #  Tool: re-crop and re-embed at higher resolution
    # ──────────────────────────────────────────────

    def _tool_rescan(self, record: dict, original_img: np.ndarray, reg_to_name: dict) -> dict | None:
        """
        Re-cut the face from the full-resolution photo with more context around
        it, scale it up, and run detection and embedding again.

        The first pass embeds whatever the whole-photo detector handed it. On a
        distant face that crop is a handful of pixels stretched to the model's
        input size. Detecting again inside an enlarged crop gives the detector
        real pixels to place landmarks on, and better landmarks mean a better
        aligned face, which is usually where a weak score actually comes from.

        Returns a fresh search result, or None if nothing usable came back.
        """
        area = record["facial_area"]
        crop = self._crop_from(original_img, area, pad=0.45)
        if crop.size == 0:
            return None

        face_w = max(1, int(area.get("w", crop.shape[1])))
        scale = round(min(4.0, max(1.0, 224 / face_w)), 2)
        crop = letterbox(crop, RESCAN_CANVAS_PX)

        try:
            preprocessed = self.svc._preprocess_image(crop)
            results = self.svc._extract_embeddings(preprocessed, enforce_detection=False)
        except Exception as e:
            print(f"[WARN] Rescan failed for face {record['face_id']}: {e}")
            return None

        if not results:
            return None

        # Enlarging adds surrounding context, which can pull in a neighbour's
        # face at the edge. The face this crop is centred on is the biggest one.
        best = max(results, key=lambda r: r[1].shape[0] * r[1].shape[1])
        embedding, new_crop, _meta = best
        search = self.svc.search_embedding(embedding, reg_to_name)
        search["crop"] = new_crop
        search["scale"] = round(scale, 2)
        return search

    # ──────────────────────────────────────────────
    #  Tool: ask Gemini to identify among candidates
    # ──────────────────────────────────────────────

    def _shortlist(self, candidates: list[dict]) -> list[dict]:
        """
        Narrow the neighbour list to the students actually worth comparing.

        The vector search happily returns five names for a face it cannot read
        at all, most of them scoring in the single digits. Sending those to a
        vision model buys nothing: they slow the request down and give it four
        extra chances to name the wrong person. The leader is always kept, so
        there is always something to compare against.
        """
        if not candidates:
            return []
        cutoff = candidates[0]["score"] * self.shortlist_ratio
        kept = [candidates[0]] + [c for c in candidates[1:] if c["score"] >= cutoff]
        return kept[: self.shortlist_max]

    def _tool_ask_gemini(self, record: dict, query_crop: np.ndarray, candidates: list[dict]) -> dict:
        """Show Gemini the face plus the shortlist and ask which student it is."""
        query_bytes = self._to_jpeg(query_crop, max_width=512, quality=88)

        payload = []
        for cand in candidates:
            photo_path = os.path.join(self.svc.known_faces_dir, f"{cand['reg_number']}.jpg")
            try:
                with open(photo_path, "rb") as f:
                    payload.append((cand["reg_number"], cand["name"], f.read()))
            except Exception:
                # A student with no readable photo simply cannot be offered as
                # an option; the others are still worth asking about.
                continue

        if not payload:
            return {"decision": "error", "confidence": None, "reason": "No registration photos available to compare."}

        return self.svc.vlm_service.identify_among_candidates(query_bytes, payload)

    # ──────────────────────────────────────────────
    #  Per-face investigation
    # ──────────────────────────────────────────────

    def _investigate(self, record: dict, original_img: np.ndarray, reg_to_name: dict) -> dict:
        """
        Work one uncertain face until it is resolved or not worth more effort.

        Tools run one after another for a single face (each choice depends on
        what the previous one found), while different faces are worked in
        parallel.
        """
        face_id = record["face_id"]
        natural_crop = self._crop_from(original_img, record["facial_area"], pad=0.3)
        top_name = reg_to_name.get(record["top_reg"], "nobody in particular")

        outcome = {
            "face_id": face_id,
            "outcome": "unsure",
            "reg_number": record["top_reg"],
            "reason": "",
            "tools_used": [],
            # Carried all the way into the result so the teacher's review screen
            # can show the actual pixels a verdict was reached on, next to the
            # student's registration photo. A name with no picture beside it is
            # something a teacher can only take on trust.
            "thumb": self._thumb(natural_crop),
            "score": round(float(record["best_score"]), 4),
        }

        quality = self._assess_quality(natural_crop, record["facial_area"], record["detector_confidence"])
        if record["tier"] == "uncertain":
            opening = (
                f"Closest match is {top_name} at {record['best_score']:.0%} similarity, "
                f"but that is below the confidence line"
            )
            if record["margin"] < self.svc.match_margin:
                opening += f" and the next-best student is only {record['margin']:.0%} behind"
            opening += "."
        else:
            opening = (
                f"No student scores high enough to be a match — best is {top_name} "
                f"at {record['best_score']:.0%}. This could be a bad crop of a student, or someone not in the class."
            )

        self._emit(
            "observe",
            f"Looking closer at face #{face_id + 1}",
            face_id=face_id,
            detail=f"{opening} The crop itself is {quality['summary']}.",
            thumb=self._thumb(natural_crop),
            quality=quality,
            best_score=round(record["best_score"], 4),
        )

        search = record
        query_crop = natural_crop

        # ── Decision 1: is this a picture problem or an identity problem? ──
        if quality["is_small"] or quality["is_blurry"]:
            self._emit(
                "think",
                "The picture is the problem, not the person",
                face_id=face_id,
                detail="Re-cutting this face from the full-resolution photo and measuring again before asking anyone else. This is free and takes milliseconds.",
                tool="rescan_at_higher_resolution",
            )
            rescan = self._tool_rescan(record, original_img, reg_to_name)
            outcome["tools_used"].append("rescan_at_higher_resolution")

            if rescan is None:
                self._emit(
                    "tool",
                    "Re-crop found no face to measure",
                    face_id=face_id,
                    detail="The enlarged crop did not give the detector anything better to work with.",
                    tool="rescan_at_higher_resolution",
                    outcome="failed",
                )
            else:
                delta = rescan["best_score"] - record["best_score"]
                new_tier = self.svc.classify_score(rescan["best_score"], rescan["margin"])
                new_name = reg_to_name.get(rescan["top_reg"], "nobody")
                self._emit(
                    "tool",
                    f"Re-measured at {rescan['scale']}x: {record['best_score']:.0%} → {rescan['best_score']:.0%}",
                    face_id=face_id,
                    detail=(
                        f"Closest match is now {new_name}. "
                        + ("That is a real improvement." if delta > 0.01 else "Barely moved — the resolution was not the issue.")
                    ),
                    tool="rescan_at_higher_resolution",
                    outcome=new_tier,
                    score_delta=round(delta, 4),
                )

                if new_tier == "confident" and rescan["skip_reason"] is None:
                    outcome["score"] = round(float(rescan["best_score"]), 4)
                    outcome.update(
                        outcome="present",
                        reg_number=rescan["top_reg"],
                        reason=f"Resolved locally: re-cropping at {rescan['scale']}x lifted the match to {rescan['best_score']:.0%}.",
                        resolved_by="rescan",
                    )
                    self._emit(
                        "verdict",
                        f"Face #{face_id + 1} is {new_name} — marked present",
                        face_id=face_id,
                        detail="Settled without spending a Gemini call.",
                        outcome="present",
                        reg_number=rescan["top_reg"],
                    )
                    return outcome

                # Even when it did not settle the question, a better embedding
                # means a better shortlist to put in front of Gemini.
                if rescan["candidates"]:
                    search = rescan
                    query_crop = self._crop_from(original_img, record["facial_area"], pad=0.3)

        # ── Decision 2: escalate to a second opinion ──
        candidates = self._shortlist(search.get("candidates") or record.get("candidates") or [])
        if not candidates:
            outcome["reason"] = "Nobody in the class was close enough to be worth comparing."
            self._emit(
                "verdict",
                f"Face #{face_id + 1} left unresolved",
                face_id=face_id,
                detail=outcome["reason"],
                outcome="unsure",
            )
            return outcome

        if not self.svc.vlm_service.is_configured:
            outcome["reason"] = "Second opinion unavailable (Gemini is not configured)."
            self._emit("verdict", f"Face #{face_id + 1} left unresolved", face_id=face_id, detail=outcome["reason"], outcome="unsure")
            return outcome

        if self._time_left() < 5:
            outcome["reason"] = "Ran out of time budget before a second opinion could be taken."
            self._emit("verdict", f"Face #{face_id + 1} left unresolved", face_id=face_id, detail=outcome["reason"], outcome="unsure")
            return outcome

        shortlist = ", ".join(f"{c['name']} ({c['score']:.0%})" for c in candidates)
        if len(candidates) == 1:
            framing = (
                f"Only {candidates[0]['name']} is close enough to be worth comparing "
                f"({candidates[0]['score']:.0%}), and that is not a convincing score. "
                "Sending the face to Gemini to ask whether it is really them — or nobody enrolled."
            )
        else:
            framing = (
                f"The numbers cannot separate these {len(candidates)} students: {shortlist}. "
                "Sending the face and all of them to Gemini and asking which one it is — "
                "or whether it is none of them."
            )
        self._emit(
            "think",
            "Asking for a second opinion",
            face_id=face_id,
            detail=framing,
            tool="gemini_identify",
        )

        verdict = self._tool_ask_gemini(record, query_crop, candidates)
        outcome["tools_used"].append("gemini_identify")
        decision = verdict.get("decision")
        reason = verdict.get("reason", "")
        confidence = verdict.get("confidence")

        if decision == "error":
            outcome["reason"] = f"Second opinion could not be reached: {reason}"
            self._emit(
                "tool",
                "Second opinion failed",
                face_id=face_id,
                detail=f"{reason} Leaving this face unresolved rather than guessing — a failed check is not a rejection.",
                tool="gemini_identify",
                outcome="error",
            )
            self._emit("verdict", f"Face #{face_id + 1} needs a human", face_id=face_id, detail=outcome["reason"], outcome="unsure")
            return outcome

        if decision == "none":
            outcome.update(
                outcome="stranger",
                reg_number=None,
                reason=reason or "Not any of the enrolled students.",
                resolved_by="gemini_identify",
            )
            self._emit(
                "tool",
                "Gemini says this is none of the candidates",
                face_id=face_id,
                detail=reason,
                tool="gemini_identify",
                outcome="none",
                confidence=confidence,
            )
            self._emit(
                "verdict",
                f"Face #{face_id + 1} is not an enrolled student",
                face_id=face_id,
                detail="Nobody is marked present for this face. An unenrolled person in the room is reported, not assigned to whoever scored highest.",
                outcome="stranger",
            )
            return outcome

        chosen_name = reg_to_name.get(decision, decision)
        corrected = decision != record["top_reg"]

        # Two weak signals are not a match. When the maths gave this face no
        # support at all, a merely "medium" or "low" confidence identification
        # is not enough to mark somebody present — the model has been handed a
        # near-unreadable face and asked to pick from a list, and picking is
        # what models do. Marking an absent student present is the one error
        # nobody can catch afterwards, so it is left for a human instead.
        if record["tier"] == "unrecognized" and confidence != "high":
            outcome["reason"] = (
                f"Gemini suggested {chosen_name}, but only with {confidence or 'unstated'} confidence, "
                f"and the local match was too weak to support anyone. Not enough to mark a student present."
            )
            self._emit(
                "tool",
                f"Gemini suggests {chosen_name}, without conviction",
                face_id=face_id,
                detail=reason,
                tool="gemini_identify",
                outcome="weak",
                confidence=confidence,
            )
            self._emit(
                "verdict",
                f"Face #{face_id + 1} needs a human",
                face_id=face_id,
                detail=(
                    "Neither the measurements nor the second opinion is convincing on its own, "
                    "and two weak signals do not add up to one strong one. Marking an absent "
                    "student present is the mistake nobody catches later."
                ),
                outcome="unsure",
            )
            return outcome
        outcome.update(
            outcome="present",
            reg_number=decision,
            reason=reason,
            resolved_by="gemini_identify",
            corrected=corrected,
        )

        self._emit(
            "tool",
            f"Gemini identifies this as {chosen_name}",
            face_id=face_id,
            detail=reason + (f" (confidence: {confidence})" if confidence else ""),
            tool="gemini_identify",
            outcome="identified",
            confidence=confidence,
        )
        if corrected:
            self._emit(
                "verdict",
                f"Correction: face #{face_id + 1} is {chosen_name}, not {top_name}",
                face_id=face_id,
                detail="The vector search had the wrong student at the top. A yes/no check would only have said 'no' — showing the whole shortlist is what allowed the right answer to surface.",
                outcome="present",
                reg_number=decision,
                corrected=True,
            )
        else:
            self._emit(
                "verdict",
                f"Face #{face_id + 1} confirmed as {chosen_name} — marked present",
                face_id=face_id,
                detail="The weak score was a photo problem, not a wrong identity.",
                outcome="present",
                reg_number=decision,
            )
        return outcome

    # ──────────────────────────────────────────────
    #  Main loop
    # ──────────────────────────────────────────────

    def run(self, original_img, preprocessed_img, all_students, reg_to_name) -> dict:
        recognized, unsure = set(), set()
        vlm_verified = set()
        evidence: dict[str, dict] = {}
        strangers = []
        processing = {"status": "success", "error": None}

        self._emit("status", "Scanning the photo for faces", detail="Detecting every face, then measuring each one against the enrolled students.")

        records = self.svc.analyze_faces(preprocessed_img, reg_to_name)
        # Detection is done; the investigation budget starts now.
        self._budget_starts_at = time.time()

        if not records:
            self._emit("status", "No faces found in this photo", detail="Nothing to mark. Try a clearer or closer shot.")
            return self.svc._assemble_result(all_students, recognized, unsure, vlm_verified, processing)

        confident, to_investigate = [], []
        for record in records:
            if record["skip_reason"] == "stale_identity":
                print(f"[WARN] Skipping stale index identity: {record['top_reg']}")
                continue
            if record["tier"] == "confident" and record["skip_reason"] is None:
                confident.append(record)
            else:
                to_investigate.append(record)

        for record in confident:
            reg = record["top_reg"]
            recognized.add(reg)
            evidence[reg] = {
                "resolved_by": "vector_match",
                "reason": f"Matched at {record['best_score']:.0%} similarity, clear of the runner-up.",
                "face_id": record["face_id"],
                # Every matched student gets the crop they were matched on, not
                # just the ones that needed investigating. The review screen
                # shows this beside their registration photo, and "the majority
                # that matched instantly" is exactly the set a teacher is being
                # asked to take on trust.
                "thumb": self._thumb(record["crop"]),
                "score": round(float(record["best_score"]), 4),
            }

        self._emit(
            "status",
            f"{len(records)} faces found — {len(confident)} matched immediately",
            detail=(
                f"{len(to_investigate)} face(s) are not clear-cut and need investigating."
                if to_investigate
                else "Every face was decisive. No further checks needed."
            ),
            faces_total=len(records),
            confident=len(confident),
            uncertain=len(to_investigate),
        )

        # Best-scoring faces first: if the cap or the time budget bites, the
        # faces most likely to resolve are the ones that got the attention.
        to_investigate.sort(key=lambda r: r["best_score"], reverse=True)
        deferred = to_investigate[self.max_investigations:]
        to_investigate = to_investigate[: self.max_investigations]

        if deferred:
            self._emit(
                "think",
                f"Investigating the {len(to_investigate)} most promising faces",
                detail=f"{len(deferred)} weaker face(s) are being left for a human rather than spending the whole time budget on long shots.",
            )

        if to_investigate:
            self._emit(
                "think",
                "Planning the checks",
                detail="Cheapest check first: anything that looks like a bad crop gets re-cut and re-measured locally. Only what survives that goes to Gemini.",
            )

            try:
                with concurrent.futures.ThreadPoolExecutor(max_workers=self.max_workers) as pool:
                    futures = {
                        pool.submit(self._investigate, r, original_img, reg_to_name): r
                        for r in to_investigate
                    }
                    for future in concurrent.futures.as_completed(futures):
                        record = futures[future]
                        try:
                            result = future.result()
                        except Exception as e:
                            print(f"[ERROR] Investigation of face {record['face_id']} crashed: {e}")
                            if record["top_reg"]:
                                unsure.add(record["top_reg"])
                            continue

                        reg = result.get("reg_number")
                        if result["outcome"] == "present" and reg:
                            # A second face resolving to somebody already found
                            # changes nothing about attendance, but it must not
                            # overwrite how they were found. The strong evidence
                            # is the one worth keeping and showing.
                            if reg in recognized:
                                self._emit(
                                    "think",
                                    f"{reg_to_name.get(reg, reg)} is already accounted for",
                                    face_id=result["face_id"],
                                    detail="Another face in this photo was already matched to them, and that match was the stronger one. Attendance is unchanged.",
                                )
                                continue

                            recognized.add(reg)
                            unsure.discard(reg)
                            if "gemini_identify" in result["tools_used"]:
                                vlm_verified.add(reg)
                            evidence[reg] = {
                                "resolved_by": result.get("resolved_by"),
                                "reason": result["reason"],
                                "face_id": result["face_id"],
                                "corrected": result.get("corrected", False),
                                "thumb": result.get("thumb"),
                                "score": result.get("score"),
                            }
                        elif result["outcome"] == "stranger":
                            strangers.append({
                                "face_id": result["face_id"],
                                "reason": result["reason"],
                                "thumb": result.get("thumb"),
                            })
                        elif reg and reg not in recognized:
                            unsure.add(reg)
                            evidence.setdefault(
                                reg,
                                {
                                    "resolved_by": "unresolved",
                                    "reason": result["reason"],
                                    "face_id": result["face_id"],
                                    "thumb": result.get("thumb"),
                                    "score": result.get("score"),
                                },
                            )
            except Exception as exc:
                processing["status"] = "partial"
                processing["error"] = str(exc)
                print(f"[ERROR] Adjudication error: {exc}")

        for record in deferred:
            if record["top_reg"] and record["top_reg"] not in recognized and record["tier"] == "uncertain":
                unsure.add(record["top_reg"])

        result = self.svc._assemble_result(
            all_students=all_students,
            recognized_reg_numbers=recognized,
            unsure_reg_numbers=unsure,
            vlm_verified_reg_numbers=vlm_verified,
            processing=processing,
            evidence=evidence,
        )
        result["unknown_faces"] = strangers
        result["faces_detected"] = len(records)
        result["investigated"] = len(to_investigate)
        result["elapsed_seconds"] = round(time.time() - self._started_at, 2)

        corrections = sum(1 for e in evidence.values() if e.get("corrected"))
        summary_bits = [f"{len(recognized)} present"]
        if unsure:
            summary_bits.append(f"{len(unsure)} still unsure")
        if strangers:
            summary_bits.append(f"{len(strangers)} unenrolled face(s)")
        if corrections:
            summary_bits.append(f"{corrections} correction(s) to the vector search")

        self._emit(
            "status",
            "Done — " + ", ".join(summary_bits),
            detail=f"Finished in {result['elapsed_seconds']}s.",
            final=True,
        )
        return result
