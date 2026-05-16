import { useState, useEffect, useCallback } from "react";
import { CheckCircle, AlertCircle, AlertTriangle, RefreshCw, Wrench, Download } from "lucide-react";
import { Button, Spinner } from "@heroui/react";
import type { DoctorResult } from "../types";
import { useToast } from "../context/ToastContext";

function StatusIcon({ severity }: { severity: string }) {
  if (severity === "ok") return <CheckCircle className="size-4 text-green-status shrink-0" />;
  if (severity === "warn") return <AlertTriangle className="size-4 text-amber-status shrink-0" />;
  return <AlertCircle className="size-4 text-red-500 shrink-0" />;
}

export function HealthPage() {
  const [result, setResult] = useState<DoctorResult | null>(null);
  const [loading, setLoading] = useState(true);
  const [repairing, setRepairing] = useState(false);
  const [installing, setInstalling] = useState<string | null>(null);
  const toast = useToast();

  const run = useCallback(async (repair = false) => {
    if (repair) setRepairing(true); else setLoading(true);
    try {
      const res = await fetch(repair ? "/api/doctor/repair" : "/api/doctor", {
        method: repair ? "POST" : "GET",
      });
      const j = await res.json();
      if (j.ok) {
        setResult(j.data);
        if (repair) toast("success", "Repair completed");
      } else {
        toast("error", j.error?.message ?? j.error ?? "Doctor failed");
      }
    } catch {
      toast("error", "Failed to reach server");
    } finally {
      if (repair) setRepairing(false); else setLoading(false);
    }
  }, [toast]);

  const installType = useCallback(async (type: string) => {
    if (installing) return;
    setInstalling(type);
    try {
      const res = await fetch(`/api/agent/install/${encodeURIComponent(type)}`, { method: "POST" });
      const j = await res.json();
      if (j.ok) {
        toast("success", `Installed ${type}`);
        await run();
      } else {
        toast("error", j.error?.message ?? j.error ?? `Failed to install ${type}`);
      }
    } catch {
      toast("error", `Failed to install ${type}`);
    } finally {
      setInstalling(null);
    }
  }, [installing, run, toast]);

  useEffect(() => { void run(); }, [run]);

  useEffect(() => {
    const id = setInterval(() => { void run(); }, 30_000);
    return () => clearInterval(id);
  }, [run]);

  const summary = result?.summary;
  const health = !summary
    ? null
    : summary.errors > 0
    ? "error"
    : summary.warnings > 0
    ? "warn"
    : "ok";

  // Group checks by category
  const grouped = result?.checks.reduce<Record<string, typeof result.checks>>((acc, c) => {
    (acc[c.category] ??= []).push(c);
    return acc;
  }, {}) ?? {};

  return (
    <div className="flex flex-col gap-6 pb-10">
      <div className="flex items-start justify-between">
        <div>
          <h1 className="text-[1.25rem] font-semibold tracking-tight text-ink">Health</h1>
          <p className="text-[0.875rem] text-ink-secondary">
            System diagnostics — deps, CLI binaries, auth, registry.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            size="sm"
            variant="outline"
            className="gap-1.5 border-border-subtle text-[0.8125rem] text-ink-secondary"
            onPress={() => void run()}
            isDisabled={loading || repairing}
          >
            {loading ? <Spinner size="sm" /> : <RefreshCw className="size-3.5" />}
            Refresh
          </Button>
          <Button
            size="sm"
            className="gap-1.5 bg-signal text-white text-[0.8125rem]"
            onPress={() => void run(true)}
            isDisabled={repairing || loading}
          >
            {repairing ? <Spinner size="sm" /> : <Wrench className="size-3.5" />}
            Run repair
          </Button>
        </div>
      </div>

      {/* Summary banner */}
      {health && summary && (
        <div
          className={`flex items-center gap-2 rounded-xl border px-4 py-3 text-[0.875rem] font-medium ${
            health === "ok"
              ? "border-green-200 bg-green-50 text-green-700"
              : health === "warn"
              ? "border-amber-200 bg-amber-50 text-amber-700"
              : "border-red-200 bg-red-50 text-red-700"
          }`}
        >
          <StatusIcon severity={health} />
          {health === "ok"
            ? `All ${summary.passed} checks passed`
            : health === "warn"
            ? `${summary.warnings} warning${summary.warnings !== 1 ? "s" : ""} — ${summary.passed} passed`
            : `${summary.errors} error${summary.errors !== 1 ? "s" : ""}${summary.warnings ? `, ${summary.warnings} warning${summary.warnings !== 1 ? "s" : ""}` : ""} — ${summary.passed} passed`}
        </div>
      )}

      {/* Check list grouped by category */}
      {loading && !result ? (
        <div className="flex justify-center py-16"><Spinner /></div>
      ) : (
        Object.entries(grouped).map(([category, checks]) => (
          <div key={category}>
            <h3 className="mb-2 text-[0.75rem] font-semibold uppercase tracking-wider text-ink-muted">
              {category}
            </h3>
            <div className="flex flex-col gap-1">
              {checks.map((check, i) => (
                <div
                  key={i}
                  className="flex items-center gap-3 rounded-lg border border-border-subtle bg-surface-card px-4 py-3"
                >
                  <StatusIcon severity={check.severity} />
                  <div className="flex-1 min-w-0">
                    <span className="text-[0.875rem] font-medium text-ink">{check.name}</span>
                    {check.message && (
                      <p className="mt-0.5 text-[0.8125rem] text-ink-secondary">{check.message}</p>
                    )}
                  </div>
                  <div className="flex items-center gap-2 shrink-0">
                    {check.fixable && check.severity !== "ok" && check.category === "types" ? (
                      <Button
                        size="sm"
                        variant="outline"
                        className="h-6 gap-1 border-border-subtle px-2 text-[0.7rem] text-ink-secondary"
                        onPress={() => void installType(check.name)}
                        isDisabled={installing !== null || repairing}
                      >
                        {installing === check.name ? (
                          <><Spinner size="sm" /> Installing…</>
                        ) : (
                          <><Download className="size-2.5" /> Install</>
                        )}
                      </Button>
                    ) : check.fixable && check.severity !== "ok" ? (
                      <Button
                        size="sm"
                        variant="outline"
                        className="h-6 gap-1 border-border-subtle px-2 text-[0.7rem] text-ink-secondary"
                        onPress={() => void run(true)}
                        isDisabled={installing !== null || repairing}
                      >
                        <Wrench className="size-2.5" /> Fix
                      </Button>
                    ) : null}
                    <span
                      className={`text-[0.75rem] font-medium capitalize ${
                        check.severity === "ok"
                          ? "text-green-status"
                          : check.severity === "warn"
                          ? "text-amber-status"
                          : "text-red-500"
                      }`}
                    >
                      {check.severity}
                    </span>
                  </div>
                </div>
              ))}
            </div>
          </div>
        ))
      )}
    </div>
  );
}
