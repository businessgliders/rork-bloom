/* eslint-disable */
// AUTO-GENERATED — DO NOT EDIT
// Run migrations to regenerate.

export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.18"
  }
  public: {
    Tables: {
      day_routines: {
        Row: {
          bed_time: string | null
          created_at: string
          id: string
          local_date: string
          meals: Json | null
          pregnancy_id: string
          taker_id: string
          template_id: string | null
          updated_at: string
          updated_by: string | null
          wake_time: string | null
        }
        Insert: {
          bed_time?: string | null
          created_at?: string
          id?: string
          local_date: string
          meals?: Json | null
          pregnancy_id: string
          taker_id: string
          template_id?: string | null
          updated_at?: string
          updated_by?: string | null
          wake_time?: string | null
        }
        Update: {
          bed_time?: string | null
          created_at?: string
          id?: string
          local_date?: string
          meals?: Json | null
          pregnancy_id?: string
          taker_id?: string
          template_id?: string | null
          updated_at?: string
          updated_by?: string | null
          wake_time?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "day_routines_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "day_routines_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "schedule_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      device_tokens: {
        Row: {
          activity_id: string | null
          created_at: string
          environment: string
          id: string
          pregnancy_id: string | null
          token: string
          type: string
          updated_at: string
          user_id: string
        }
        Insert: {
          activity_id?: string | null
          created_at?: string
          environment?: string
          id?: string
          pregnancy_id?: string | null
          token: string
          type: string
          updated_at?: string
          user_id?: string
        }
        Update: {
          activity_id?: string | null
          created_at?: string
          environment?: string
          id?: string
          pregnancy_id?: string | null
          token?: string
          type?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "device_tokens_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
        ]
      }
      dose_logs: {
        Row: {
          created_at: string
          id: string
          logged_by: string | null
          medication_id: string
          pregnancy_id: string
          scheduled_for: string
          status: string
          taken_at: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          logged_by?: string | null
          medication_id: string
          pregnancy_id: string
          scheduled_for: string
          status?: string
          taken_at?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          logged_by?: string | null
          medication_id?: string
          pregnancy_id?: string
          scheduled_for?: string
          status?: string
          taken_at?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "dose_logs_medication_id_fkey"
            columns: ["medication_id"]
            isOneToOne: false
            referencedRelation: "medications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "dose_logs_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
        ]
      }
      medication_follows: {
        Row: {
          medication_id: string
          mode: string
          pregnancy_id: string
          updated_at: string
          user_id: string
        }
        Insert: {
          medication_id: string
          mode: string
          pregnancy_id: string
          updated_at?: string
          user_id: string
        }
        Update: {
          medication_id?: string
          mode?: string
          pregnancy_id?: string
          updated_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "medication_follows_medication_id_fkey"
            columns: ["medication_id"]
            isOneToOne: false
            referencedRelation: "medications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medication_follows_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
        ]
      }
      medications: {
        Row: {
          active: boolean
          created_at: string
          created_by: string | null
          days_of_week: number[]
          dose: string | null
          end_date: string | null
          food_rule: string
          friendly_name: string | null
          id: string
          name: string
          no_food_after_min: number
          no_food_before_min: number
          notes: string | null
          photo_path: string | null
          pregnancy_id: string
          purpose: string | null
          rules_confirmed: boolean
          schedule_type: string
          slot: string
          start_date: string
          taken_by: string
          time_of_day: string | null
          updated_at: string
        }
        Insert: {
          active?: boolean
          created_at?: string
          created_by?: string | null
          days_of_week?: number[]
          dose?: string | null
          end_date?: string | null
          food_rule?: string
          friendly_name?: string | null
          id?: string
          name: string
          no_food_after_min?: number
          no_food_before_min?: number
          notes?: string | null
          photo_path?: string | null
          pregnancy_id: string
          purpose?: string | null
          rules_confirmed?: boolean
          schedule_type?: string
          slot?: string
          start_date?: string
          taken_by?: string
          time_of_day?: string | null
          updated_at?: string
        }
        Update: {
          active?: boolean
          created_at?: string
          created_by?: string | null
          days_of_week?: number[]
          dose?: string | null
          end_date?: string | null
          food_rule?: string
          friendly_name?: string | null
          id?: string
          name?: string
          no_food_after_min?: number
          no_food_before_min?: number
          notes?: string | null
          photo_path?: string | null
          pregnancy_id?: string
          purpose?: string | null
          rules_confirmed?: boolean
          schedule_type?: string
          slot?: string
          start_date?: string
          taken_by?: string
          time_of_day?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "medications_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
        ]
      }
      milestones: {
        Row: {
          completed: boolean
          created_at: string
          created_by: string | null
          id: string
          is_suggested: boolean
          notes: string | null
          occurs_at: string | null
          photo_path: string | null
          pregnancy_id: string
          title: string
          type: string
          updated_at: string
          week: number | null
        }
        Insert: {
          completed?: boolean
          created_at?: string
          created_by?: string | null
          id?: string
          is_suggested?: boolean
          notes?: string | null
          occurs_at?: string | null
          photo_path?: string | null
          pregnancy_id: string
          title: string
          type?: string
          updated_at?: string
          week?: number | null
        }
        Update: {
          completed?: boolean
          created_at?: string
          created_by?: string | null
          id?: string
          is_suggested?: boolean
          notes?: string | null
          occurs_at?: string | null
          photo_path?: string | null
          pregnancy_id?: string
          title?: string
          type?: string
          updated_at?: string
          week?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "milestones_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
        ]
      }
      planned_doses: {
        Row: {
          created_at: string
          id: string
          local_date: string
          medication_id: string
          no_food_after_min: number
          no_food_before_min: number
          pregnancy_id: string
          scheduled_for: string
          source: string
          taker_id: string
          template_id: string | null
          updated_at: string
        }
        Insert: {
          created_at?: string
          id?: string
          local_date: string
          medication_id: string
          no_food_after_min?: number
          no_food_before_min?: number
          pregnancy_id: string
          scheduled_for: string
          source?: string
          taker_id: string
          template_id?: string | null
          updated_at?: string
        }
        Update: {
          created_at?: string
          id?: string
          local_date?: string
          medication_id?: string
          no_food_after_min?: number
          no_food_before_min?: number
          pregnancy_id?: string
          scheduled_for?: string
          source?: string
          taker_id?: string
          template_id?: string | null
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "planned_doses_medication_id_fkey"
            columns: ["medication_id"]
            isOneToOne: false
            referencedRelation: "medications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planned_doses_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "planned_doses_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "schedule_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      pregnancies: {
        Row: {
          baby_nickname: string | null
          created_at: string
          created_by: string
          creator_role: string
          dating_date: string
          dating_method: string
          due_date: string
          id: string
          invite_code: string
          mom_name: string
          partner_name: string | null
          updated_at: string
        }
        Insert: {
          baby_nickname?: string | null
          created_at?: string
          created_by?: string
          creator_role?: string
          dating_date: string
          dating_method?: string
          due_date: string
          id?: string
          invite_code?: string
          mom_name: string
          partner_name?: string | null
          updated_at?: string
        }
        Update: {
          baby_nickname?: string | null
          created_at?: string
          created_by?: string
          creator_role?: string
          dating_date?: string
          dating_method?: string
          due_date?: string
          id?: string
          invite_code?: string
          mom_name?: string
          partner_name?: string | null
          updated_at?: string
        }
        Relationships: []
      }
      pregnancy_members: {
        Row: {
          joined_at: string
          pregnancy_id: string
          role: string
          user_id: string
        }
        Insert: {
          joined_at?: string
          pregnancy_id: string
          role: string
          user_id: string
        }
        Update: {
          joined_at?: string
          pregnancy_id?: string
          role?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "pregnancy_members_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
        ]
      }
      profiles: {
        Row: {
          created_at: string
          display_name: string | null
          id: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          display_name?: string | null
          id: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          display_name?: string | null
          id?: string
          updated_at?: string
        }
        Relationships: []
      }
      schedule_rules: {
        Row: {
          confirmed: boolean
          created_at: string
          id: string
          max_minutes: number | null
          min_minutes: number | null
          pregnancy_id: string
          relation: string
          source_text: string | null
          subject_medication_id: string
          taker_id: string
          target_meal: string | null
          target_medication_id: string | null
          target_type: string
          updated_at: string
        }
        Insert: {
          confirmed?: boolean
          created_at?: string
          id?: string
          max_minutes?: number | null
          min_minutes?: number | null
          pregnancy_id: string
          relation: string
          source_text?: string | null
          subject_medication_id: string
          taker_id: string
          target_meal?: string | null
          target_medication_id?: string | null
          target_type: string
          updated_at?: string
        }
        Update: {
          confirmed?: boolean
          created_at?: string
          id?: string
          max_minutes?: number | null
          min_minutes?: number | null
          pregnancy_id?: string
          relation?: string
          source_text?: string | null
          subject_medication_id?: string
          taker_id?: string
          target_meal?: string | null
          target_medication_id?: string | null
          target_type?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "schedule_rules_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_rules_subject_medication_id_fkey"
            columns: ["subject_medication_id"]
            isOneToOne: false
            referencedRelation: "medications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "schedule_rules_target_medication_id_fkey"
            columns: ["target_medication_id"]
            isOneToOne: false
            referencedRelation: "medications"
            referencedColumns: ["id"]
          },
        ]
      }
      schedule_templates: {
        Row: {
          active: boolean
          bed_time: string
          created_at: string
          created_by: string | null
          days_of_week: number[]
          id: string
          meals: Json
          name: string
          pregnancy_id: string
          taker_id: string
          updated_at: string
          wake_time: string
        }
        Insert: {
          active?: boolean
          bed_time: string
          created_at?: string
          created_by?: string | null
          days_of_week?: number[]
          id?: string
          meals?: Json
          name: string
          pregnancy_id: string
          taker_id: string
          updated_at?: string
          wake_time: string
        }
        Update: {
          active?: boolean
          bed_time?: string
          created_at?: string
          created_by?: string | null
          days_of_week?: number[]
          id?: string
          meals?: Json
          name?: string
          pregnancy_id?: string
          taker_id?: string
          updated_at?: string
          wake_time?: string
        }
        Relationships: [
          {
            foreignKeyName: "schedule_templates_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
        ]
      }
      template_items: {
        Row: {
          created_at: string
          duration_min: number
          id: string
          kind: string
          label: string | null
          medication_id: string | null
          pinned: boolean
          pregnancy_id: string
          sort_order: number
          template_id: string
          time_of_day: string
          updated_at: string
        }
        Insert: {
          created_at?: string
          duration_min?: number
          id?: string
          kind: string
          label?: string | null
          medication_id?: string | null
          pinned?: boolean
          pregnancy_id: string
          sort_order?: number
          template_id: string
          time_of_day: string
          updated_at?: string
        }
        Update: {
          created_at?: string
          duration_min?: number
          id?: string
          kind?: string
          label?: string | null
          medication_id?: string | null
          pinned?: boolean
          pregnancy_id?: string
          sort_order?: number
          template_id?: string
          time_of_day?: string
          updated_at?: string
        }
        Relationships: [
          {
            foreignKeyName: "template_items_medication_id_fkey"
            columns: ["medication_id"]
            isOneToOne: false
            referencedRelation: "medications"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "template_items_pregnancy_id_fkey"
            columns: ["pregnancy_id"]
            isOneToOne: false
            referencedRelation: "pregnancies"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "template_items_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "schedule_templates"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      [_ in never]: never
    }
    Functions: {
      get_push_webhook_secret: { Args: never; Returns: string }
      join_pregnancy: { Args: { p_code: string }; Returns: string }
    }
    Enums: {
      [_ in never]: never
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends (DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never) = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends (DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never) = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends (PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never) = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {},
  },
} as const
