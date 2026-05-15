export {
  Bot,
  Code2,
  Sparkles,
  Zap,
  Bird,
  Wrench,
  MoreVertical,
  Play,
  Square,
  RotateCw,
  Trash2,
  ChevronLeft,
  ArrowLeft,
  RefreshCw,
  Terminal,
  Send,
  BarChart2,
  Plus,
  ExternalLink,
} from "lucide-react";

import type { LucideIcon } from "lucide-react";
import { Bot, Code2, Sparkles, Zap, Bird, Wrench } from "lucide-react";

export const TYPE_ICON: Record<string, LucideIcon> = {
  claude:   Bot,
  codex:    Code2,
  gemini:   Sparkles,
  hermes:   Zap,
  openclaw: Bird,
  opencode: Wrench,
};
