---------------- MODULE EnvManagerVerification ----------------
EXTENDS Naturals, Sequences, TLC

VARIABLES transition_state, ibl_state

vars == <<transition_state, ibl_state>>

TransitionStates == { "Idle", "Loading", "Wait_IBL", "Fade_Out", "Fade_In" }
IBLStates == { "Idle", "Upload_Texture", "Upload_Progressive", "Generate_Mipmaps", "Luminance", "Specular_Init", "Specular_Mips", "Irradiance", "Done" }

TransitionTransitions == {
    << "Idle", "Loading" >>,
    << "Loading", "Idle" >>,
    << "Loading", "Wait_IBL" >>,
    << "Wait_IBL", "Fade_In" >>,
    << "Wait_IBL", "Fade_Out" >>,
    << "Fade_Out", "Fade_In" >>,
    << "Fade_In", "Idle" >>,
    << "Wait_IBL", "Idle" >>,
    << "Fade_Out", "Idle" >>
}

IBLTransitions == {
    << "Idle", "Upload_Texture" >>,
    << "Upload_Texture", "Upload_Progressive" >>,
    << "Upload_Texture", "Idle" >>,
    << "Upload_Progressive", "Generate_Mipmaps" >>,
    << "Upload_Progressive", "Idle" >>,
    << "Generate_Mipmaps", "Luminance" >>,
    << "Generate_Mipmaps", "Idle" >>,
    << "Luminance", "Specular_Init" >>,
    << "Luminance", "Idle" >>,
    << "Specular_Init", "Specular_Mips" >>,
    << "Specular_Init", "Idle" >>,
    << "Specular_Mips", "Irradiance" >>,
    << "Specular_Mips", "Idle" >>,
    << "Irradiance", "Done" >>,
    << "Irradiance", "Idle" >>,
    << "Done", "Idle" >>
}

TypeOK == 
    /\ transition_state \in TransitionStates
    /\ ibl_state \in IBLStates

Init == 
    /\ transition_state = "Wait_IBL"
    /\ ibl_state = "Idle"

(* --- Transition Actions --- *)

StartTransition == 
    /\ transition_state = "Idle"
    /\ transition_state' = "Loading"
    /\ UNCHANGED <<ibl_state>>

LoaderFailed == 
    /\ transition_state = "Loading"
    /\ transition_state' = "Idle"
    /\ UNCHANGED <<ibl_state>>

LoaderSucceeds == 
    /\ transition_state = "Loading"
    /\ transition_state' = "Wait_IBL"
    /\ ibl_state' = "Upload_Texture"

(* Progress of the progressive IBL calculation *)
IBL_Progress_UploadTexture == 
    /\ transition_state = "Wait_IBL"
    /\ ibl_state = "Upload_Texture"
    /\ (ibl_state' = "Upload_Progressive" \/ ibl_state' = "Idle")
    /\ UNCHANGED <<transition_state>>

IBL_Progress_UploadProgressive == 
    /\ transition_state = "Wait_IBL"
    /\ ibl_state = "Upload_Progressive"
    /\ (ibl_state' = "Generate_Mipmaps" \/ ibl_state' = "Idle")
    /\ UNCHANGED <<transition_state>>

IBL_Progress_GenerateMipmaps == 
    /\ transition_state = "Wait_IBL"
    /\ ibl_state = "Generate_Mipmaps"
    /\ (ibl_state' = "Luminance" \/ ibl_state' = "Idle")
    /\ UNCHANGED <<transition_state>>

IBL_Progress_Luminance == 
    /\ (transition_state = "Wait_IBL" \/ transition_state = "Fade_In")
    /\ ibl_state = "Luminance"
    /\ (ibl_state' = "Specular_Init" \/ ibl_state' = "Idle")
    /\ UNCHANGED <<transition_state>>

IBL_Progress_SpecularInit == 
    /\ (transition_state = "Wait_IBL" \/ transition_state = "Fade_In")
    /\ ibl_state = "Specular_Init"
    /\ (ibl_state' = "Specular_Mips" \/ ibl_state' = "Idle")
    /\ UNCHANGED <<transition_state>>

IBL_Progress_SpecularMips == 
    /\ (transition_state = "Wait_IBL" \/ transition_state = "Fade_In")
    /\ ibl_state = "Specular_Mips"
    /\ (ibl_state' = "Irradiance" \/ ibl_state' = "Idle")
    /\ UNCHANGED <<transition_state>>

IBL_Progress_Irradiance == 
    /\ (transition_state = "Wait_IBL" \/ transition_state = "Fade_In")
    /\ ibl_state = "Irradiance"
    /\ (ibl_state' = "Done" \/ ibl_state' = "Idle")
    /\ UNCHANGED <<transition_state>>

IBL_Complete_Crossfade == 
    /\ transition_state = "Wait_IBL"
    /\ ibl_state = "Done"
    /\ ibl_state' = "Idle"
    /\ transition_state' = "Fade_In"

IBL_Complete_BlackScreen == 
    /\ transition_state = "Wait_IBL"
    /\ ibl_state = "Done"
    /\ ibl_state' = "Idle"
    /\ transition_state' = "Fade_Out"

FadeOutComplete == 
    /\ transition_state = "Fade_Out"
    /\ transition_state' = "Fade_In"
    /\ UNCHANGED <<ibl_state>>

FadeInComplete == 
    /\ transition_state = "Fade_In"
    /\ transition_state' = "Idle"
    /\ UNCHANGED <<ibl_state>>

(* Allow manual cancel from Wait_IBL back to Idle *)
CancelTransition == 
    /\ (transition_state = "Wait_IBL" \/ transition_state = "Fade_Out")
    /\ transition_state' = "Idle"
    /\ ibl_state' = "Idle"

Next == 
    \/ StartTransition
    \/ LoaderFailed
    \/ LoaderSucceeds
    \/ IBL_Progress_UploadTexture
    \/ IBL_Progress_UploadProgressive
    \/ IBL_Progress_GenerateMipmaps
    \/ IBL_Progress_Luminance
    \/ IBL_Progress_SpecularInit
    \/ IBL_Progress_SpecularMips
    \/ IBL_Progress_Irradiance
    \/ IBL_Complete_Crossfade
    \/ IBL_Complete_BlackScreen
    \/ FadeOutComplete
    \/ FadeInComplete
    \/ CancelTransition

Spec == Init /\ [][Next]_vars /\ WF_vars(Next)

(* Invariant SafeTransition: IBL state machine must remain Idle unless a transition is active *)
SafeTransition == 
    transition_state = "Idle" => ibl_state = "Idle"

Liveness == []<> (transition_state = "Idle")
===================================================================
