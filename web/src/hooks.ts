import { useEffect, useState, type Dispatch, type SetStateAction } from "react";
import { ApiError, getMyCohort, type MyCohortDetail } from "./api";

/** 내 기수 하나를 읽는다. 라우트가 바뀌면 다시 읽고, 늦게 온 옛 응답은 버린다. */
export function useMyCohort(cohortId: number | null): {
  cohort: MyCohortDetail | null;
  error: string | null;
  setCohort: Dispatch<SetStateAction<MyCohortDetail | null>>;
} {
  const [cohort, setCohort] = useState<MyCohortDetail | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    setCohort(null);
    if (cohortId === null) {
      setError("없는 기수입니다.");
      return;
    }
    setError(null);
    let cancelled = false;
    getMyCohort(cohortId)
      .then((c) => !cancelled && setCohort(c))
      .catch((err: ApiError) => !cancelled && setError(err.message));
    return () => {
      cancelled = true;
    };
  }, [cohortId]);

  return { cohort, error, setCohort };
}
