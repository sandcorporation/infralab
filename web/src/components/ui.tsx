import { useEffect, useRef, type ReactNode, type RefObject } from "react";
import { NavLink } from "react-router-dom";
import { IconClose } from "../shell/icons";

/** 페이지 머리: 제목(+ 배지), 보조 줄, 오른쪽 주 버튼. */
export function PageHead({
  title,
  badges,
  sub,
  actions,
}: {
  title: ReactNode;
  badges?: ReactNode;
  sub?: ReactNode;
  actions?: ReactNode;
}) {
  return (
    <div className="sc-page-head">
      <div>
        <h1 className="sc-page-head-title">
          {title}
          {badges}
        </h1>
        {sub && <p className="sc-page-head-sub">{sub}</p>}
      </div>
      {actions && <div className="sc-page-head-actions">{actions}</div>}
    </div>
  );
}

export type TabItem = { to: string; label: string; count?: number; end?: boolean };

/**
 * 가로로 밀리는 줄(탭·요약 타일)이 오른쪽에 더 있으면 data-fade-end 를 단다 — CSS 가 오른쪽 끝을 흐리게 한다.
 * 끝까지 밀면 흐림이 사라진다.
 */
export function useScrollFade<T extends HTMLElement>(): RefObject<T> {
  const ref = useRef<T>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const update = () => {
      if (el.scrollLeft + el.clientWidth < el.scrollWidth - 1) el.dataset.fadeEnd = "";
      else delete el.dataset.fadeEnd;
    };
    update();
    el.addEventListener("scroll", update, { passive: true });
    const ro = typeof ResizeObserver === "undefined" ? null : new ResizeObserver(update);
    ro?.observe(el);
    return () => {
      el.removeEventListener("scroll", update);
      ro?.disconnect();
    };
  });
  return ref;
}

/** 요약 타일 줄(sc-stat). 폰에선 한 줄로 가로로 밀린다. */
export function StatRow({ items }: { items: { label: ReactNode; value: ReactNode; note?: ReactNode }[] }) {
  const ref = useScrollFade<HTMLDListElement>();
  return (
    <dl className="sc-stat" ref={ref}>
      {items.map((it, i) => (
        <div className="sc-stat-item" key={i}>
          <dt className="sc-stat-label">{it.label}</dt>
          <dd className="sc-stat-value">{it.value}</dd>
          {it.note !== undefined && <dd className="sc-stat-note">{it.note}</dd>}
        </div>
      ))}
    </dl>
  );
}

/** 링크 탭(하위 경로). 탭 상태가 URL 에 남는다. */
export function LinkTabs({ label, items }: { label: string; items: TabItem[] }) {
  const ref = useScrollFade<HTMLElement>();
  return (
    <nav className="sc-tabs" aria-label={label} ref={ref}>
      {items.map((t) => (
        <NavLink key={t.to} to={t.to} end={t.end}>
          {t.label}
          {t.count !== undefined && <span className="sc-tabs-count">{t.count}</span>}
        </NavLink>
      ))}
    </nav>
  );
}

/** 네이티브 <dialog> 를 open 값에 맞춰 showModal()/close() 한다. Esc·배경 누름은 onClose. */
function useModal(open: boolean, onClose: () => void) {
  const ref = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) d.showModal();
    if (!open && d.open) d.close();
  }, [open]);
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    const onCancel = (e: Event) => {
      e.preventDefault();
      onClose();
    };
    const onClick = (e: MouseEvent) => e.target === d && onClose();
    d.addEventListener("cancel", onCancel);
    d.addEventListener("click", onClick);
    return () => {
      d.removeEventListener("cancel", onCancel);
      d.removeEventListener("click", onClick);
    };
  }, [onClose]);
  return ref;
}

/** 가운데 상자(만들기·발급·확인). foot 에 버튼들. */
export function Modal({
  open,
  title,
  onClose,
  children,
  foot,
}: {
  open: boolean;
  title: string;
  onClose: () => void;
  children: ReactNode;
  foot: ReactNode;
}) {
  const ref = useModal(open, onClose);
  return (
    <dialog className="sc-dialog" ref={ref} aria-label={title}>
      {open && (
        <>
          <div className="sc-dialog-body">
            <h2 className="sc-dialog-title">{title}</h2>
            {children}
          </div>
          <div className="sc-dialog-foot">{foot}</div>
        </>
      )}
    </dialog>
  );
}

/** 되돌리기 어려운 동작의 확인 상자. 안전한 쪽(취소)에 포커스. */
export function ConfirmDialog({
  open,
  title,
  children,
  confirmLabel,
  busy,
  onConfirm,
  onClose,
}: {
  open: boolean;
  title: string;
  children?: ReactNode;
  confirmLabel: string;
  busy?: boolean;
  onConfirm: () => void;
  onClose: () => void;
}) {
  return (
    <Modal
      open={open}
      title={title}
      onClose={onClose}
      foot={
        <>
          <button type="button" className="secondary" autoFocus onClick={onClose}>
            취소
          </button>
          <button type="button" className="sc-btn sc-btn--danger sc-btn--sm" disabled={busy} onClick={onConfirm}>
            {confirmLabel}
          </button>
        </>
      }
    >
      {children}
    </Modal>
  );
}

/** 오른쪽 서랍(세부 보기). */
export function Drawer({
  open,
  title,
  onClose,
  children,
  foot,
  wide,
}: {
  open: boolean;
  title: ReactNode;
  onClose: () => void;
  children: ReactNode;
  foot?: ReactNode;
  /** 표·증거처럼 넓은 내용: 440px 대신 760px. */
  wide?: boolean;
}) {
  const ref = useModal(open, onClose);
  return (
    <dialog className={wide ? "sc-drawer app-drawer-wide" : "sc-drawer"} ref={ref}>
      {open && (
        <>
          <div className="sc-drawer-head">
            <h2 className="sc-drawer-title">{title}</h2>
            <button type="button" className="sc-icon-btn" aria-label="닫기" onClick={onClose}>
              <IconClose />
            </button>
          </div>
          <div className="sc-drawer-body">{children}</div>
          {foot && <div className="sc-drawer-foot">{foot}</div>}
        </>
      )}
    </dialog>
  );
}
