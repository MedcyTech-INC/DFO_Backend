import { Injectable } from '@nestjs/common';
import { SupabaseClient } from '@supabase/supabase-js';

@Injectable()
export class ClinicsUtilsService {
    isUuid(value: string): boolean {
        return /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/.test(value);
    }

    sanitizePayload<T extends Record<string, any>>(payload: T): T {
        const sanitized = { ...payload } as Record<string, any>;
        Object.keys(sanitized).forEach((key) => {
            if (sanitized[key] === undefined) {
                delete sanitized[key];
            }
        });
        return sanitized as T;
    }

    toValue(val: any): any {
        if (val === undefined || val === null) return undefined;
        if (typeof val === 'string' && val.trim() === '') return undefined;
        return val;
    }

    async generateUhid(supabase: SupabaseClient): Promise<string> {
        const now = new Date();
        const year = now.getFullYear();

        const { data, error } = await supabase
            .from('opdesk_sakhi_clinic_patients')
            .select('uhid')
            .ilike('uhid', `JAN-${year}-%`);

        if (error) throw error;

        let maxSequence = 0;
        if (data && data.length > 0) {
            for (const row of data) {
                if (row.uhid) {
                    const parts = row.uhid.split('-');
                    if (parts.length === 3) {
                        const seq = parseInt(parts[2], 10);
                        if (!isNaN(seq) && seq > maxSequence) {
                            maxSequence = seq;
                        }
                    }
                }
            }
        }

        const nextNumber = maxSequence + 1;
        const sequence = String(nextNumber).padStart(3, '0');
        return `JAN-${year}-${sequence}`;
    }

    async backfillPatientSnapshot(supabase: SupabaseClient, appointmentId: string): Promise<void> {
        const { data: appointment, error: appointmentError } = await supabase
            .from('opdesk_sakhi_clinic_appointments')
            .select('id, patient_id, patient_name_snapshot, patient_phone_snapshot, patient_dob_snapshot')
            .eq('id', appointmentId)
            .single();

        if (appointmentError) {
            if (appointmentError.code === 'PGRST116') return;
            throw appointmentError;
        }

        if (!appointment?.patient_id) return;

        const hasSnapshots =
            appointment.patient_name_snapshot &&
            appointment.patient_phone_snapshot &&
            appointment.patient_dob_snapshot;

        if (hasSnapshots) return;

        const { data: patient, error: patientError } = await supabase
            .from('opdesk_sakhi_clinic_patients')
            .select('name, mobile, dob')
            .eq('id', appointment.patient_id)
            .single();

        if (patientError) {
            if (patientError.code === 'PGRST116') return;
            throw patientError;
        }

        if (!patient) return;

        const updates = this.sanitizePayload({
            patient_name_snapshot: appointment.patient_name_snapshot || patient.name,
            patient_phone_snapshot: appointment.patient_phone_snapshot || patient.mobile,
            patient_dob_snapshot: appointment.patient_dob_snapshot || patient.dob,
        });

        if (!Object.keys(updates).length) return;

        await supabase.from('opdesk_sakhi_clinic_appointments').update(updates).eq('id', appointmentId);
    }

    normalizeTime(timeStr?: string): string {
        if (!timeStr) return '';
        const parts = timeStr.trim().split(':');
        const h = parts[0]?.padStart(2, '0') || '00';
        const m = parts[1]?.padStart(2, '0') || '00';
        return `${h}:${m}`;
    }

    async checkGlobalDoctorAvailability(
        supabase: SupabaseClient,
        doctorId: string,
        appointmentDate: string,
        startTime: string,
        endTime: string,
        excludeAppointmentId?: string
    ): Promise<{ isAvailable: boolean; conflictClinicId?: string; reason?: string }> {
        const normStart = this.normalizeTime(startTime);
        const normEnd = this.normalizeTime(endTime);

        // 0. Check doctor leaves
        const { data: leaves, error: leavesError } = await supabase
            .from('opdesk_sakhi_clinic_doctor_leaves')
            .select('*')
            .eq('doctor_id', doctorId)
            .eq('leave_date', appointmentDate);
        if (leavesError) throw leavesError;
        if (leaves && leaves.length > 0) {
            return { isAvailable: false, reason: 'Doctor is on leave on this date.' };
        }

        // 0.5 Check weekly schedule
        const dateObj = new Date(appointmentDate);
        const dayOfWeek = dateObj.getDay();
        const { data: schedules, error: schedulesError } = await supabase
            .from('opdesk_sakhi_clinic_doctor_schedules')
            .select('*')
            .eq('doctor_id', doctorId)
            .eq('day_of_week', dayOfWeek)
            .eq('is_active', true);
        if (schedulesError) throw schedulesError;
        
        if (!schedules || schedules.length === 0) {
            return { isAvailable: false, reason: 'Doctor does not work on this day.' };
        }

        const isWithinSchedule = schedules.some(schedule => {
            const schedStart = this.normalizeTime(schedule.start_time);
            const schedEnd = this.normalizeTime(schedule.end_time);
            return normStart >= schedStart && normEnd <= schedEnd;
        });

        if (!isWithinSchedule) {
             return { isAvailable: false, reason: "Requested time is outside the doctor's working hours." };
        }

        // 1. Check if doctor availability slots exist for this date
        const { data: slots, error: slotsError } = await supabase
            .from('opdesk_sakhi_clinic_availability_slots')
            .select('*')
            .eq('doctor_id', doctorId)
            .eq('slot_date', appointmentDate);
        
        if (slotsError) throw slotsError;

        let maxCapacity = 1;

        if (slots && slots.length > 0) {
            // Find slot(s) that match or cover the requested appointment time
            const matchingSlots = slots.filter(s => {
                const sStart = this.normalizeTime(s.start_time);
                const sEnd = this.normalizeTime(s.end_time);
                return sStart < normEnd && sEnd > normStart;
            });

            if (matchingSlots.length === 0) {
                return { isAvailable: false, reason: 'Doctor is not scheduled to work at this specific time.' };
            }

            // Effective capacity is the minimum capacity of all overlapping slots (typically 1)
            maxCapacity = Math.min(...matchingSlots.map(s => s.capacity || 1));
        }

        // 2. Check overlapping appointments to ensure we haven't exceeded capacity
        let query = supabase
            .from('opdesk_sakhi_clinic_appointments')
            .select('id, clinic_id, start_time, end_time')
            .eq('doctor_id', doctorId)
            .eq('appointment_date', appointmentDate)
            .not('status', 'in', '("Canceled","No Show")');

        if (excludeAppointmentId) {
            query = query.neq('id', excludeAppointmentId);
        }

        const { data: existingAppts, error } = await query;
        if (error) throw error;

        if (existingAppts && existingAppts.length > 0) {
            let overlappingCount = 0;
            let conflictClinicId: string | undefined = undefined;
            
            for (const appt of existingAppts) {
                const apptStart = this.normalizeTime(appt.start_time);
                const apptEnd = this.normalizeTime(appt.end_time);

                // If the appointment overlaps with our requested time
                if (normStart < apptEnd && normEnd > apptStart) {
                    overlappingCount++;
                    conflictClinicId = appt.clinic_id;
                }
            }

            if (overlappingCount >= maxCapacity) {
                return { isAvailable: false, conflictClinicId, reason: 'Maximum patient capacity reached for this time slot.' };
            }
        }

        return { isAvailable: true };
    }

    async incrementSlotBooking(supabase: SupabaseClient, doctorId: string, date: string, startTime: string): Promise<void> {
        const normStartTime = this.normalizeTime(startTime);
        const { data: slots } = await supabase
            .from('opdesk_sakhi_clinic_availability_slots')
            .select('id, capacity, booked_count, start_time, end_time')
            .eq('doctor_id', doctorId)
            .eq('slot_date', date);
            
        const matchingSlot = slots?.find(s => {
            const sStart = this.normalizeTime(s.start_time);
            const sEnd = this.normalizeTime(s.end_time);
            return sStart <= normStartTime && sEnd > normStartTime;
        });

        if (matchingSlot) {
            const newCount = (matchingSlot.booked_count || 0) + 1;
            const capacity = matchingSlot.capacity || 1;
            await supabase
                .from('opdesk_sakhi_clinic_availability_slots')
                .update({ 
                    booked_count: newCount,
                    status: newCount >= capacity ? 'BOOKED' : 'AVAILABLE',
                    updated_at: new Date().toISOString()
                })
                .eq('id', matchingSlot.id);
        }
    }

    async decrementSlotBooking(supabase: SupabaseClient, doctorId: string, date: string, startTime: string): Promise<void> {
        const normStartTime = this.normalizeTime(startTime);
        const { data: slots } = await supabase
            .from('opdesk_sakhi_clinic_availability_slots')
            .select('id, capacity, booked_count, start_time, end_time')
            .eq('doctor_id', doctorId)
            .eq('slot_date', date);
            
        const matchingSlot = slots?.find(s => {
            const sStart = this.normalizeTime(s.start_time);
            const sEnd = this.normalizeTime(s.end_time);
            return sStart <= normStartTime && sEnd > normStartTime;
        });

        if (matchingSlot && matchingSlot.booked_count > 0) {
            const newCount = Math.max(0, matchingSlot.booked_count - 1);
            await supabase
                .from('opdesk_sakhi_clinic_availability_slots')
                .update({ 
                    booked_count: newCount,
                    status: 'AVAILABLE',
                    updated_at: new Date().toISOString()
                })
                .eq('id', matchingSlot.id);
        }
    }
}
