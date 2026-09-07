// Drift TypeConverters.
//
// Currently none are required: ParkedSales.payload stays a plain TEXT column
// holding a JSON string (encoded/decoded by the repository layer, not the DB).
// If a future table chooses to store a typed JSON map directly, add a
// JsonMapConverter here and apply it with `.map(const JsonMapConverter())`.
//
// Kept as a dedicated file so the schema/build layout matches the agreed
// topology; intentionally empty of converters for schema v1.
