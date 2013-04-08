; Project name	:	XTIDE Universal BIOS
; Description	:	Int 13h function AH=48h, Get Extended Drive Parameters.

;
; XTIDE Universal BIOS and Associated Tools
; Copyright (C) 2009-2010 by Tomi Tilli, 2011-2013 by XTIDE Universal BIOS Team.
;
; This program is free software; you can redistribute it and/or modify
; it under the terms of the GNU General Public License as published by
; the Free Software Foundation; either version 2 of the License, or
; (at your option) any later version.
;
; This program is distributed in the hope that it will be useful,
; but WITHOUT ANY WARRANTY; without even the implied warranty of
; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
; GNU General Public License for more details.
; Visit http://www.gnu.org/licenses/old-licenses/gpl-2.0.html
;

; Section containing code
SECTION .text

;--------------------------------------------------------------------
; Int 13h function AH=48h, Get Extended Drive Parameters.
;
; It is not completely clear what this function should return as total sector count in some cases.
; What is certain is that:
; A) Phoenix Enhanced Disk Drive Specification v3.0 says that P-CHS values
;    are never returned for drives with more than 15,482,880 sectors (16384*15*63).
;    For those drives we can simply return total sector count from
;    ATA ID WORDs 60 and 61 (LBA28) or WORDs 100-103 (LBA48).
; B) IBM PC DOS 7.1 fdisk32 displays warning message if P-CHS values multiplied
;    together are different than total sector count. Therefore for drives with less
;    than or equal 15,482,880 sectors we MUST NOT return total sector count from
;    ATA ID WORDs 60 and 61.
;
;    Lets take an example. 6 GB Hitachi microdrive reports following values in ATA ID:
;    Sector count from WORDs 60 and 61	: 12,000,556
;    Cylinders							: 11905
;    Heads								:    16
;    Sectors per track					:    63
;
;    When multiplying C*H*S we get		: 12,000,240
;    So the CHS size is a little bit less than LBA size. But we must use
;    the smaller value since C*H*S must equal total sector count!
;
; Now we get to the uncertain area where I could not find any information.
; Award BIOS from 1997 Pentium motherboard returns following values:
;    AH=08h L-CHS:   745, 255, 63 (exactly the same as what we return)
;    => Total Sector Count:		  745*255*63 = 11,968,425
;    AH=48h P-CHS: 11873,  16, 63
;    AH=48h Total Sector Count: 11873* 16*63 = 11,967,984
;
; Notice how AH=48h returns lesser total sector count than AH=8h! The only
; way I could think of to get 11873 cylinders is to divide AH=08h sector
; count with P-CHS heads and sectors: (745*255*63) / (16*63) = 11873
;
; I have no idea what is the reasoning behind it but at least there is one
; BIOS that does just that.
;
; I decided that we multiply P-CHS values and do not waste space like the
; Award BIOS does.
;
;
; AH48h_GetExtendedDriveParameters
;	Parameters:
;		SI:		Same as in INTPACK
;		DL:		Translated Drive number
;		DS:DI:	Ptr to DPT (in RAMVARS segment)
;		SS:BP:	Ptr to IDEPACK
;	Parameters on INTPACK:
;		DS:SI:	Ptr to Extended Drive Information Table to fill
;	Returns with INTPACK:
;		AH:		Int 13h return status
;		DS:SI:	Ptr to Extended Drive Information Table
;		CF:		0 if successful, 1 if error
;--------------------------------------------------------------------
AH48h_HandlerForGetExtendedDriveParameters:
	mov		si, di
	push	ds
	pop		es		; ES = RAMVARS segment
	xor		bx, bx
	dec		bx		; Set to FFFFh to assume we do not return DPTE

	; Create DPTE (hardware information for device drivers)
%ifdef RETURN_DPTE_ON_AH48H
	call	AH41h_GetSupportBitsToCX
	test	cl, ENHANCED_DISK_DRIVE_SUPPORT
	jz		SHORT .DoNotCreateDPTE
	call	CreateDeviceParameterTableExtensionToESBXfromDPTinDSSI
.DoNotCreateDPTE:
%endif

	; Point DS:DI to Extended Drive Information Table to fill
	mov		di, [bp+IDEPACK.intpack+INTPACK.si]
	mov		ds, [bp+IDEPACK.intpack+INTPACK.ds]

	; Check and adjust Extended Drive Information Table size
	; to MINIMUM_EDRIVEINFO_SIZE or EDRIVEINFO_SIZE_WITH_DPTE
	mov		ax, MINIMUM_EDRIVEINFO_SIZE
	mov		cx, [di+EDRIVE_INFO.wSize]
	cmp		cx, ax
	jb		Prepare_ReturnFromInt13hWithInvalidFunctionError
	mov		[di+EDRIVE_INFO.wSize], ax
	add		al, EDRIVEINFO_SIZE_WITH_DPTE - MINIMUM_EDRIVEINFO_SIZE
	cmp		cx, ax
	jb		SHORT .SkipEddConfigurationParameters
	mov		[di+EDRIVE_INFO.wSize], ax

	; Store DPTE for standard controllers only,
	; FFFF:FFFF for non standard controllers
%ifdef RETURN_DPTE_ON_AH48H
	mov		[di+EDRIVE_INFO.fpDPTE], bx
	mov		[di+EDRIVE_INFO.fpDPTE+2], es
	inc		bx
	jnz		SHORT .SkipEddConfigurationParameters	; Already stored
	dec		bx
	mov		[di+EDRIVE_INFO.fpDPTE+2], bx	; Segment = FFFFh
%else
	mov		[di+EDRIVE_INFO.fpDPTE], bx
	mov		[di+EDRIVE_INFO.fpDPTE+2], bx
%endif

	; Fill Extended Drive Information Table in DS:DI from DPT in ES:SI
.SkipEddConfigurationParameters:
	mov		WORD [di+EDRIVE_INFO.wFlags], FLG_DMA_BOUNDARY_ERRORS_HANDLED_BY_BIOS

	; Store total sector count
	call	Registers_ExchangeDSSIwithESDI
	call	AccessDPT_GetLbaSectorCountToBXDXAX
	call	Registers_ExchangeDSSIwithESDI
	mov		[di+EDRIVE_INFO.qwTotalSectors], ax
	mov		[di+EDRIVE_INFO.qwTotalSectors+2], dx
	mov		[di+EDRIVE_INFO.qwTotalSectors+4], bx
	xor		cx, cx
	mov		[di+EDRIVE_INFO.qwTotalSectors+6], cx	; Always zero
	mov		WORD [di+EDRIVE_INFO.wSectorSize], 512

	; Store P-CHS. Based on phoenix specification this is returned only if
	; total sector count is 15,482,880 or less.
	sub		ax, 4001h
	sbb		dx, 0ECh
	sbb		bx, cx		; Zero
	jnc		SHORT .ReturnWithSuccess	; More than EC4000h
	or		WORD [di+EDRIVE_INFO.wFlags], FLG_CHS_INFORMATION_IS_VALID

	eMOVZX	dx, BYTE [es:si+DPT.bPchsHeads]
	mov		[di+EDRIVE_INFO.dwHeads], dx
	mov		[di+EDRIVE_INFO.dwHeads+2], cx

	mov		dl, [es:si+DPT.bPchsSectorsPerTrack]
	mov		[di+EDRIVE_INFO.dwSectorsPerTrack], dx
	mov		[di+EDRIVE_INFO.dwSectorsPerTrack+2], cx

	mov		dx, [es:si+DPT.wPchsCylinders]
	mov		[di+EDRIVE_INFO.dwCylinders], dx
	mov		[di+EDRIVE_INFO.dwCylinders+2], cx

.ReturnWithSuccess:
	xor		ax, ax
.ReturnWithError:
	jmp		Int13h_ReturnFromHandlerAfterStoringErrorCodeFromAH


%ifdef RETURN_DPTE_ON_AH48H
;--------------------------------------------------------------------
; CreateDeviceParameterTableExtensionToESBXfromDPTinDSSI
;	Parameters:
;		DS:SI:	Ptr to DPT (in RAMVARS segment)
;		ES:		RAMVARS segment
;	Returns:
;		ES:BX:	Ptr to Device Parameter Table Extension (DPTE)
;	Corrupts registers:
;		AX, CX, DX, DI
;--------------------------------------------------------------------
CreateDeviceParameterTableExtensionToESBXfromDPTinDSSI:
	; Point ES:DI to DPTE buffer (valid until next AH=48h call)
	mov		di, [cs:ROMVARS.bStealSize]
	eSHL_IM	di, 10							; DI = RAMVARS size in bytes
	sub		di, BYTE DPTE_size				; DI = Offset to DPTE
	xor		dx, dx							; Clear for checksum

	; Set 32-bit flag for 32-bit controllers
	mov		cx, FLG_LBA_TRANSLATION_ENABLED	; DPTE.wFlags
	cmp		BYTE [si+DPT_ATA.bDevice], DEVICE_32BIT_ATA
	eCMOVE	cl, FLG_LBA_TRANSLATION_ENABLED | FLG_32BIT_XFER_MODE

	; DPTE.wBasePort
	mov		ax, [si+DPT.wBasePort]
	call	StoswThenAddALandAHtoDL			; Bytes 0 and 1

	; DPTE.wControlBlockPort
	eMOVZX	bx, BYTE [si+DPT.bIdevarsOffset]
	mov		ax, [cs:bx+IDEVARS.wControlBlockPort]
	call	StoswThenAddALandAHtoDL			; Bytes 2 and 3

	; DPTE.bDrvnhead and DPTE.bBiosVendor
	xchg	di, si
	call	AccessDPT_GetDriveSelectByteForEbiosToAL
	xchg	si, di
	call	StoswThenAddALandAHtoDL			; Bytes 4 and 5

	; DPTE.bIRQ and DPTE.bBlockSize
	mov		al, [cs:bx+IDEVARS.bIRQ]		; No way to define that we might not use IRQ
	mov		ah, [si+DPT_ATA.bBlockSize]
	cmp		ah, 1
	jbe		SHORT .DoNotSetBlockModeFlag
	or		cl, FLG_BLOCK_MODE_ENABLED
.DoNotSetBlockModeFlag:
	call	StoswThenAddALandAHtoDL			; Bytes 6 and 7

	; DPTE.bDmaChannelAndType and DPTE.bPioMode
	xor		ax, ax
%ifdef MODULE_ADVANCED_ATA
	or		ah, [si+DPT_ADVANCED_ATA.bPioMode]
	jz		SHORT .NoDotSetFastPioFlag
	cmp		WORD [si+DPT_ADVANCED_ATA.wControllerID], BYTE 0
	je		SHORT .NoDotSetFastPioFlag
	inc		cx		; FLG_FAST_PIO_ENABLED
.NoDotSetFastPioFlag:
%endif
	call	StoswThenAddALandAHtoDL			; Bytes 8 and 9

	; Set CHS translation flags and store DPTE.wFlags
	mov		al, [si+DPT.bFlagsLow]
	and		al, MASKL_DPT_TRANSLATEMODE
	jz		SHORT .NoChsTranslationOrBitShiftTranslationSet
	or		cl, FLG_CHS_TRANSLATION_ENABLED
	test	al, FLGL_DPT_ASSISTED_LBA
	jz		SHORT .NoChsTranslationOrBitShiftTranslationSet
	or		cx, LBA_ASSISTED_TRANSLATION << TRANSLATION_TYPE_FIELD_POSITION
.NoChsTranslationOrBitShiftTranslationSet:
	xchg	ax, cx
	call	StoswThenAddALandAHtoDL			; Bytes 10 and 11

	; DPTE.wReserved (must be zero)
	xor		ax, ax
	call	StoswThenAddALandAHtoDL			; Bytes 12 and 13

	; DPTE.bRevision and DPTE.bChecksum
	mov		ax, DPTE_REVISION | (DPTE_REVISION<<8)
	add		ah, dl
	neg		ah
	stosw
	lea		bx, [di-DPTE_size]
	ret


;--------------------------------------------------------------------
; StoswThenAddALandAHtoDL
;	Parameters:
;		AX:		WORD to store
;		ES:DI:	Ptr to where to store AX
;		DL:		Checksum byte
;	Returns:
;		DL:		Checksum byte
;		DI:		Incremented by 2
;	Corrupts registers:
;		Nothing
;--------------------------------------------------------------------
StoswThenAddALandAHtoDL:
	stosw
	add		dl, al
	add		dl, ah
	ret

%endif ; RETURN_DPTE_ON_AH48H
