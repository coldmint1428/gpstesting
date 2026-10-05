// Supabase client (supabase-js, MIT licence).
// The URL and anon key come from .env (see .env.example). The anon key is safe
// in the browser because Row Level Security (RLS) decides what each user can do.
// NEVER put the service-role key here.
import { createClient } from '@supabase/supabase-js'

const url = import.meta.env.VITE_SUPABASE_URL
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

// If .env is missing, export null so pages can still work without the database.
export const supabase = url && anonKey ? createClient(url, anonKey) : null
