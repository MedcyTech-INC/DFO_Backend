import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { createClient, SupabaseClient } from '@supabase/supabase-js';
import { Agent as UndiciAgent } from 'undici';
import { TenantContext } from '../../../infrastructure/context/tenant.context';

@Injectable()
export class ClinicsSupabaseService {
    private readonly logger = new Logger(ClinicsSupabaseService.name);
    private client: SupabaseClient;
    private readonly anonKey: string;
    private readonly supabaseUrl: string;

    constructor(private readonly configService: ConfigService) {
        const url = this.configService.get<string>('ORG_SUPABASE_URL') ?? this.configService.get<string>('app.orgSupabase.url') ?? this.configService.get<string>('SUPABASE_URL') ?? this.configService.get<string>('app.supabase.url');
        const key = this.configService.get<string>('ORG_SUPABASE_SERVICE_ROLE_KEY') ?? this.configService.get<string>('ORG_SUPABASE_KEY') ?? this.configService.get<string>('app.orgSupabase.key') ?? this.configService.get<string>('SUPABASE_SERVICE_ROLE_KEY') ?? this.configService.get<string>('SUPABASE_KEY') ?? this.configService.get<string>('app.supabase.key');

        if (!url || !key) {
            this.logger.error('Supabase credentials missing (SUPABASE_URL / SUPABASE_KEY / SUPABASE_SERVICE_ROLE_KEY)');
            throw new Error('Supabase credentials are missing');
        }

        this.client = createClient(url, key, {
            auth: {
                autoRefreshToken: false,
                persistSession: false,
            }
        });

        // Initialize anon key for RLS queries
        this.anonKey = this.configService.get<string>('ORG_SUPABASE_ANON_KEY') ?? this.configService.get<string>('SUPABASE_ANON_KEY') ?? this.configService.get<string>('app.supabase.anonKey') ?? key;
        this.supabaseUrl = url;

        this.logger.log('Supabase admin client initialized for Clinics module');
    }

    getClient(): SupabaseClient {
        const state = TenantContext.getState();
        const token = state?.raw_token;

        if (token && this.anonKey && this.anonKey !== this.client['supabaseKey']) { // Fallback if anonKey is the same as service role key
            return createClient(this.supabaseUrl, this.anonKey, {
                global: {
                    headers: {
                        Authorization: `Bearer ${token}`,
                    },
                },
                auth: {
                    autoRefreshToken: false,
                    persistSession: false,
                },
            });
        }
        
        // Fallback to service role client if no JWT token is present in context (e.g. background jobs)
        return this.client;
    }

    getAdminClient(): SupabaseClient {
        return this.client;
    }
}
