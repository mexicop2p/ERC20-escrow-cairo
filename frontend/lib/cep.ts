import { z } from "zod";

export const cepSchema = z.object({
  fecha: z
    .string()
    .refine((value) => !Number.isNaN(Date.parse(value)), { message: "Use YYYY-MM-DD" }),
  claveRastreo: z.string().min(10),
  emisor: z.string().length(3),
  receptor: z.string().length(3),
  cuenta: z.string().min(10),
  montoCentavos: z.number().int().nonnegative(),
  pagoABanco: z.boolean().optional().default(false)
});

export type CepPayload = z.infer<typeof cepSchema>;

export type CepValidationResult = {
  valid: boolean;
  error?: string;
  transferencia?: Record<string, unknown>;
  raw?: string;
};

export const validateCep = async (payload: CepPayload): Promise<CepValidationResult> => {
  const response = await fetch("/api/validate-cep", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    return { valid: false, error: `CEP validation failed with status ${response.status}` };
  }

  return response.json();
};
