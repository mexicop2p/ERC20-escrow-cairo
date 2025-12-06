import { z } from "zod";

const dateValidator = z
  .string()
  .refine((value) => !Number.isNaN(Date.parse(value)), { message: "Use YYYY-MM-DD" });

export const cepSchema = z.object({
  fecha: dateValidator,
  claveRastreo: z
    .string()
    .regex(/^[A-Za-z0-9]{6,30}$/u, "Clave de rastreo debe tener 6-30 caracteres alfanuméricos"),
  emisor: z.string().regex(/^\d{5}$/u, "Clave del banco emisor debe tener 5 dígitos"),
  receptor: z.string().regex(/^\d{5}$/u, "Clave del banco receptor debe tener 5 dígitos"),
  cuenta: z.string().regex(/^\d{18}$/u, "La cuenta (CLABE) debe tener 18 dígitos"),
  montoCentavos: z.number().int().positive({ message: "Monto en centavos debe ser mayor a 0" }),
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
