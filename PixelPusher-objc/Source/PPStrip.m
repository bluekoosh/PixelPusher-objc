//
//  PPStrip.m
//  PixelPusher-objc
//
//  Created by Rus Maxham on 5/28/13.
//  Copyright (c) 2013 rrrus. All rights reserved.
//

#import "PPDeviceRegistry.h"
#import "PPPixel.h"
#import "PPPixelPusher.h"
#import "PPStrip.h"

typedef void (^PPSetPixWithFloatBlock)(uint32_t index, float red, float green, float blue);
typedef void (^PPSetPixWithShortBlock)(uint32_t index, uint16_t red, uint16_t green, uint16_t blue);
typedef void (^PPSetPixWithByteBlock)(uint32_t index, uint8_t red, uint8_t green, uint8_t blue);

static PPCurveBlock gOutputCurveFunction;
static const uint8_t * gOutputLUT8 = nil;
static uint16_t* gOutputLUT16 = nil;

void PPStripBuildOutputCurve(int depth);

@interface PPStrip ()
@property (nonatomic, assign) uint32_t pixelCount;
@property (nonatomic, assign) uint32_t stripNumber;
@property (nonatomic, assign) uint32_t flags;
@property (nonatomic, assign) void* buffer;
@property (nonatomic, assign) size_t bufferSize;
@property (nonatomic, assign) PPPixelType bufferPixType;
@property (nonatomic, assign) PPComponentType bufferCompType;
@property (nonatomic, assign) size_t bufferPixStride;
@property (nonatomic, assign) uint32_t bufferPixCount;
@property (nonatomic, strong) NSMutableData* internallyAllocatedBuffer;

@property (nonatomic, strong) PPSetPixWithByteBlock setPixWithByte;
@property (nonatomic, strong) PPSetPixWithShortBlock setPixWithShort;
@property (nonatomic, strong) PPSetPixWithFloatBlock setPixWithFloat;
@end

@implementation PPStrip

- (id)initWithStripNumber:(int32_t)stripNum pixelCount:(int32_t)pixCount flags:(int32_t)flags{
	self = [self init];
	if (self) {
		self.stripNumber = stripNum;
		self.flags = flags;
		self.touched = YES;
		self.powerScale = 1;
		self.brightnessScale = 1;
		self.brightness = PPFloatPixelMake(1, 1, 1);

		PPComponentType compType = ePPCompTypeByte;
		if (self.flags & SFLAG_WIDEPIXELS) {
			compType = ePPCompTypeShort;
			pixCount = (pixCount+1)/2;
			if (!gOutputLUT16) PPStripBuildOutputCurve(16);
		} else {
			if (!gOutputLUT8) PPStripBuildOutputCurve(8);
		}

		self.pixelCount = pixCount;

		[self setPixelBuffer:nil
						size:0
				   pixelType:ePPPixTypeRGB
			   componentType:compType
				 pixelStride:0];
	}
	return self;
}

- (NSString *)description {
	return [NSString stringWithFormat:@"%@ (%d%@)", super.description, self.stripNumber, self.touched?@" dirty":@""];
}

- (BOOL)isWidePixel {
	return (_flags & SFLAG_WIDEPIXELS) != 0;
}

- (BOOL)isRGBOWPixel {
	return (_flags & SFLAG_RGBOW) != 0;
}

- (void)setPixelAtIndex:(uint32_t)index withByteRed:(uint8_t)red green:(uint8_t)green blue:(uint8_t)blue {
	if (!_setPixWithByte) [self configureSetPix];
	_setPixWithByte(index, red, green, blue);
	_touched = YES;
}

- (void)setPixelAtIndex:(uint32_t)index withShortRed:(uint16_t)red green:(uint16_t)green blue:(uint16_t)blue {
	if (!_setPixWithShort) [self configureSetPix];
	_setPixWithShort(index, red, green, blue);
	_touched = YES;
}

- (void)setPixelAtIndex:(uint32_t)index withFloatRed:(float)red green:(float)green blue:(float)blue {
	if (!_setPixWithFloat) [self configureSetPix];
	_setPixWithFloat(index, red, green, blue);
	_touched = YES;
}

- (void)setPixelBuffer:(void*)buffer
				  size:(size_t)size
			 pixelType:(PPPixelType)pixType
		 componentType:(PPComponentType)compType
		   pixelStride:(size_t)stride
{
	// if the requested format is the same as what we have already and
	// the buffer is the basically the same, early exit.
	if (_bufferCompType == compType
		&& _bufferPixType == pixType
		&& _bufferPixStride == stride
		&& (	(buffer == nil && _internallyAllocatedBuffer)
			 || (buffer != nil && buffer == _buffer)
			)
		)
	{
		return;
	}
	
	if (stride == 0) {
		int nComps = (pixType == ePPPixTypeRGBOW) ? 5 : 3;
		int compSize;
		switch (compType) {
			case ePPCompTypeFloat: compSize = sizeof(float); break;
			case ePPCompTypeShort: compSize = sizeof(uint16_t); break;
			case ePPCompTypeByte:  compSize = sizeof(uint8_t); break;
			default:
				NSAssert(NO, @"unknown pixel component type specified");
		}
		stride = nComps * compSize;
	}
	
	self.bufferPixStride = stride;
	self.bufferPixType = pixType;
	self.bufferCompType = compType;
	
	if (buffer == nil) {
		// allocate buffer internally using specified pixel types
		size = _pixelCount * stride;
		self.internallyAllocatedBuffer = [NSMutableData dataWithCapacity:size];
		buffer = self.internallyAllocatedBuffer.mutableBytes;
	} else if (self.internallyAllocatedBuffer && buffer != self.internallyAllocatedBuffer.mutableBytes) {
		// using an external buffer, don't need this anymore
		self.internallyAllocatedBuffer = nil;
	}
	
	self.bufferPixCount = (uint32_t)(size / stride);
	self.buffer = buffer;
	self.bufferSize = size;
	
	// reset the pixel setters.  don't configure them if they're not being used.
	self.setPixWithByte = nil;
	self.setPixWithShort = nil;
	self.setPixWithFloat = nil;
}

- (void)configureSetPix {
	void* stripBuffer = self.buffer;
	size_t stride = self.bufferPixStride;
	
	if (self.bufferCompType == ePPCompTypeByte) {
		// buffer has byte component pixels
		self.setPixWithByte = [^(uint32_t index, uint8_t red, uint8_t green, uint8_t blue) {
			PPBytePixel *pix = (PPBytePixel*)(stripBuffer + (index*stride));
			pix->red = red;
			pix->green = green;
			pix->blue = blue;
		} copy];
		
		self.setPixWithShort = [^(uint32_t index, uint16_t red, uint16_t green, uint16_t blue) {
			PPBytePixel *pix = (PPBytePixel*)(stripBuffer + (index*stride));
			pix->red = (uint8_t)(red >> 8);
			pix->green = (uint8_t)(green >> 8);
			pix->blue = (uint8_t)(blue >> 8);
		} copy];
		
		self.setPixWithFloat = [^(uint32_t index, float red, float green, float blue) {
			PPBytePixel *pix = (PPBytePixel*)(stripBuffer + (index*stride));
			pix->red = (uint8_t)(red * 255);
			pix->green = (uint8_t)(green * 255);
			pix->blue = (uint8_t)(blue * 255);
		} copy];
		
	} else if (self.bufferCompType == ePPCompTypeShort) {
		// buffer has short component pixels
		self.setPixWithByte = [^(uint32_t index, uint8_t red, uint8_t green, uint8_t blue) {
			PPShortPixel *pix = (PPShortPixel*)(stripBuffer + (index*stride));
			pix->red = (uint16_t)(red | (red << 8));
			pix->green = (uint16_t)(green | (green << 8));
			pix->blue = (uint16_t)(blue | (blue << 8));
		} copy];
		
		self.setPixWithShort = [^(uint32_t index, uint16_t red, uint16_t green, uint16_t blue) {
			PPShortPixel *pix = (PPShortPixel*)(stripBuffer + (index*stride));
			pix->red = red;
			pix->green = green;
			pix->blue = blue;
		} copy];
		
		self.setPixWithFloat = [^(uint32_t index, float red, float green, float blue) {
			PPShortPixel *pix = (PPShortPixel*)(stripBuffer + (index*stride));
			pix->red = (uint16_t)(red * 65535);
			pix->green = (uint16_t)(green * 65535);
			pix->blue = (uint16_t)(blue * 65535);
		} copy];
		
	} else {
		// buffer has float component pixels
		self.setPixWithByte = [^(uint32_t index, uint8_t red, uint8_t green, uint8_t blue) {
			PPFloatPixel *pix = (PPFloatPixel*)(stripBuffer + (index*stride));
			pix->red = (float)red / 255.0f;
			pix->green = (float)green / 255.0f;
			pix->blue = (float)blue / 255.0f;
		} copy];
		
		self.setPixWithShort = [^(uint32_t index, uint16_t red, uint16_t green, uint16_t blue) {
			PPFloatPixel *pix = (PPFloatPixel*)(stripBuffer + (index*stride));
			pix->red = (float)red / 65535.0f;
			pix->green = (float)green / 65535.0f;
			pix->blue = (float)blue / 65535.0f;
		} copy];
		
		self.setPixWithFloat = [^(uint32_t index, float red, float green, float blue) {
			PPFloatPixel *pix = (PPFloatPixel*)(stripBuffer + (index*stride));
			pix->red = red;
			pix->green = green;
			pix->blue = blue;
		} copy];
		
	}
}

- (float)calcAverageBrightnessValue {

#define SUM_PIX_WITH_LUT(scale) \
sum += gOutputLUT8[ (uint8_t)((uint16_t)(srcPix->red   * scale) / 256) ]; \
sum += gOutputLUT8[ (uint8_t)((uint16_t)(srcPix->green * scale) / 256) ]; \
sum += gOutputLUT8[ (uint8_t)((uint16_t)(srcPix->blue  * scale) / 256) ];

	uint8_t *srcP = self.buffer;
	uint32_t numPix = MIN(self.bufferPixCount, self.pixelCount);
	uint8_t* endP = srcP + numPix*_bufferPixStride;
	const size_t stride = _bufferPixStride;
	float average;

	// use output curve to map to brightness
	if (gOutputCurveFunction != sCurveLinearFunction) {
		// this may fire with 16-bit pixels.  fix it when we have some to test with
		NSAssert(gOutputLUT8 != nil, @"no 8-bit lookup table!");
		if (self.bufferCompType == ePPCompTypeByte) {
			uint32_t sum = 0;
			while (srcP < endP) {
				PPBytePixel *srcPix = (PPBytePixel*)srcP;
				SUM_PIX_WITH_LUT(256);
				srcP += stride;
			}
			average = (float)sum / (numPix * 3 * 255);
		} else if (self.bufferCompType == ePPCompTypeShort) {
			uint32_t sum = 0;
			while (srcP < endP) {
				PPShortPixel *srcPix = (PPShortPixel*)srcP;
				SUM_PIX_WITH_LUT(1);
				srcP += stride;
			}
			average = (float)sum / (numPix * 3 * 255);
		} else {
			float sum = 0;
			while (srcP < endP) {
				PPFloatPixel *srcPix = (PPFloatPixel*)srcP;
				SUM_PIX_WITH_LUT(65535);
				srcP += stride;
			}
			average = sum / (numPix * 3 * 255);
		}
	} else {
		if (self.bufferCompType == ePPCompTypeByte) {
			uint32_t sum = 0;
			while (srcP < endP) {
				PPBytePixel *srcPix = (PPBytePixel*)srcP;
				sum += srcPix->red; sum += srcPix->green; sum += srcPix->blue;
				srcP += stride;
			}
			average = (float)sum / (numPix * 3 * 255);
		} else if (self.bufferCompType == ePPCompTypeShort) {
			uint32_t sum = 0;
			while (srcP < endP) {
				PPShortPixel *srcPix = (PPShortPixel*)srcP;
				sum += srcPix->red; sum += srcPix->green; sum += srcPix->blue;
				srcP += stride;
			}
			average = (float)sum / (numPix * 3 * 65535);
		} else {
			float sum = 0;
			while (srcP < endP) {
				PPFloatPixel *srcPix = (PPFloatPixel*)srcP;
				sum += srcPix->red; sum += srcPix->green; sum += srcPix->blue;
				srcP += stride;
			}
			average = sum / (numPix * 3);
		}
	}
	
	return average;
}

- (uint32_t)serialize:(uint8_t*)buffer size:(size_t)size {
	
#define COPY_PIX_WITH_LUT(scale) \
*(P++) = (uint8_t)(gOutputLUT8[ (uint8_t)((uint16_t)(srcPix->red   * scale) / 256) ] * iPostLutScaleRed / 65536); \
*(P++) = (uint8_t)(gOutputLUT8[ (uint8_t)((uint16_t)(srcPix->green * scale) / 256) ] * iPostLutScaleGrn / 65536); \
*(P++) = (uint8_t)(gOutputLUT8[ (uint8_t)((uint16_t)(srcPix->blue  * scale) / 256) ] * iPostLutScaleBlu / 65536); \
srcP += stride;

#define COPY_PIX(scale) \
*(P++) = (uint8_t)( (uint16_t)(srcPix->red   * scale) * iPostLutScaleRed / (256*65536)); \
*(P++) = (uint8_t)( (uint16_t)(srcPix->green * scale) * iPostLutScaleGrn / (256*65536)); \
*(P++) = (uint8_t)( (uint16_t)(srcPix->blue  * scale) * iPostLutScaleBlu / (256*65536)); \
srcP += stride;

#define COPY_PIX_WIDE_WITH_LUT(scale) \
uint16_t wide; \
wide = (uint16_t)(gOutputLUT16[ (uint16_t)(srcPix->red   * scale) ] * iPostLutScaleRed / 65536); \
*P = (wide & 0xff00) >> 8; \
*(P+3) = (wide & 0x00ff); \
P++; \
wide = (uint16_t)(gOutputLUT16[ (uint16_t)(srcPix->green * scale) ] * iPostLutScaleGrn / 65536); \
*P = (wide & 0xff00) >> 8; \
*(P+3) = (wide & 0x00ff); \
P++; \
wide = (uint16_t)(gOutputLUT16[ (uint16_t)(srcPix->blue  * scale) ] * iPostLutScaleBlu / 65536); \
*P = (wide & 0xff00) >> 8; \
*(P+3) = (wide & 0x00ff); \
P += 4; /* skip the next 3 bytes we already filled in */ \
srcP += stride;

#define COPY_PIX_WIDE(scale) \
uint16_t wide; \
wide = (uint16_t) ((uint16_t)(srcPix->red   * scale) * iPostLutScaleRed / 65536); \
*P = (wide & 0xff00) >> 8; \
*(P+3) = (wide & 0x00ff); \
P++; \
wide = (uint16_t) ((uint16_t)(srcPix->green * scale) * iPostLutScaleGrn / 65536); \
*P = (wide & 0xff00) >> 8; \
*(P+3) = (wide & 0x00ff); \
P++; \
wide = (uint16_t) ((uint16_t)(srcPix->blue  * scale) * iPostLutScaleBlu / 65536); \
*P = (wide & 0xff00) >> 8; \
*(P+3) = (wide & 0x00ff); \
P += 4; /* skip the next 3 bytes we already filled in */ \
srcP += stride;

	// convert brightness plus powerScale to 16-bit binary fraction
	const uint32_t iPostLutScaleRed = (uint32_t)(_brightness.red   * _powerScale * _brightnessScale * 65536);
	const uint32_t iPostLutScaleGrn = (uint32_t)(_brightness.green * _powerScale * _brightnessScale * 65536);
	const uint32_t iPostLutScaleBlu = (uint32_t)(_brightness.blue  * _powerScale * _brightnessScale * 65536);

	// figure out how much to copy based on the smallest of the strip's pixels,
	// the destination buffer size, the source buffer size.
	size_t destPix = size/3;
	if (_flags & SFLAG_WIDEPIXELS) destPix /= 2;
	destPix = MIN(destPix, _pixelCount);
	uint32_t pixToCopy = MIN(_bufferPixCount, destPix);
	
	const size_t stride = _bufferPixStride;
	uint8_t *srcP = _buffer;
	uint8_t *endP = srcP + pixToCopy * stride;
	uint8_t *P = buffer;
	
	if (_flags & SFLAG_WIDEPIXELS) {
		if (gOutputCurveFunction != sCurveLinearFunction) {
			
			if (_bufferCompType == ePPCompTypeByte) {
				while (srcP < endP) {
					PPBytePixel *srcPix = (PPBytePixel*)srcP;
					COPY_PIX_WIDE_WITH_LUT(256);
				}
			} else if (_bufferCompType == ePPCompTypeShort) {
				while (srcP < endP) {
					PPShortPixel *srcPix = (PPShortPixel*)srcP;
					COPY_PIX_WIDE_WITH_LUT(1);
				}
			} else {
				while (srcP < endP) {
					PPFloatPixel *srcPix = (PPFloatPixel*)srcP;
					COPY_PIX_WIDE_WITH_LUT(65535);
				}
			}
		} else {
			if (_bufferCompType == ePPCompTypeByte) {
				while (srcP < endP) {
					PPBytePixel *srcPix = (PPBytePixel*)srcP;
					COPY_PIX_WIDE(256);
				}
			} else if (_bufferCompType == ePPCompTypeShort) {
				while (srcP < endP) {
					PPShortPixel *srcPix = (PPShortPixel*)srcP;
					COPY_PIX_WIDE(1);
				}
			} else {
				while (srcP < endP) {
					PPFloatPixel *srcPix = (PPFloatPixel*)srcP;
					COPY_PIX_WIDE(65535);
				}
			}
		}
	} else {
		if (gOutputCurveFunction != sCurveLinearFunction) {
			if (_bufferCompType == ePPCompTypeByte) {
				while (srcP < endP) {
					PPBytePixel *srcPix = (PPBytePixel*)srcP;
					COPY_PIX_WITH_LUT(256);
				}
			} else if (_bufferCompType == ePPCompTypeShort) {
				while (srcP < endP) {
					PPShortPixel *srcPix = (PPShortPixel*)srcP;
					COPY_PIX_WITH_LUT(1);
				}
			} else {
				while (srcP < endP) {
					PPFloatPixel *srcPix = (PPFloatPixel*)srcP;
					COPY_PIX_WITH_LUT(65535);
				}
			}
		} else {
			if (_bufferCompType == ePPCompTypeByte) {
				while (srcP < endP) {
					PPBytePixel *srcPix = (PPBytePixel*)srcP;
					COPY_PIX(256);
				}
			} else if (_bufferCompType == ePPCompTypeShort) {
				while (srcP < endP) {
					PPShortPixel *srcPix = (PPShortPixel*)srcP;
					COPY_PIX(1);
				}
			}
			if (_bufferCompType == ePPCompTypeFloat) {
				while (srcP < endP) {
					PPFloatPixel *srcPix = (PPFloatPixel*)srcP;
					COPY_PIX(65535);
				}
			}
		}
	}
	
	// if the pixel buffer isn't big enough, pad it out with 0's
	if (pixToCopy < destPix) {
		uint32_t padding = destPix - pixToCopy;
		if (_flags & SFLAG_WIDEPIXELS) padding *= 2;
		padding *= 3;
		memset(P, 0, padding);
		P += padding;
	}
	
    _touched = NO;
	return (uint32_t)(P-buffer);
}

@end

#pragma mark - Output curve function bits

const PPCurveBlock sCurveLinearFunction =  ^float(float input) {
	return input;
};

const PPCurveBlock sCurveAntilogFunction =  ^float(float input) {
	// input range 0-1, output range 0-1
	return (powf(2, 8*input)-1)/255;
};

void PPStripBuildOutputCurve(int depth) {
	if (!gOutputCurveFunction) gOutputCurveFunction = sCurveAntilogFunction;
	
	if (depth == 16) {
		if (gOutputLUT8) free((void*)gOutputLUT8);
		gOutputLUT8 = nil;
	} else {
		if (gOutputLUT8) free((void*)gOutputLUT8);
		gOutputLUT8 = nil;
	}
	
	// special case linear output function
	if (!gOutputCurveFunction || gOutputCurveFunction == sCurveLinearFunction) {
		// give the LUTs a non-nil value so we can check to see if they're in use
		if (depth == 16) {
			gOutputLUT16 = malloc(1);
		} else {
			gOutputLUT8 = malloc(1);
		}
		return;
	}
	
	if (depth == 16) {
		uint16_t *outputLUT16 = malloc(65536);
		gOutputLUT16 = outputLUT16;
		for (int i=0; i<65536; i++) {
			outputLUT16[i] = (uint16_t)( lroundf( 65535.0f * gOutputCurveFunction(i/65535.0f) ) );
		}
	} else {
		uint8_t *outputLUT8 = malloc(256);
		gOutputLUT8 = outputLUT8;
		for (int i=0; i<256; i++) {
			outputLUT8[i] = (uint8_t)( lroundf( 255.0f * gOutputCurveFunction(i/255.0f) ) );
		}
	}
}

void PPStripSetOutputCurveFunction(PPCurveBlock curveFunction) {
	if (!curveFunction) curveFunction = sCurveLinearFunction;
	
	gOutputCurveFunction = [curveFunction copy];
	// only rebuild if they already exist
	if (gOutputLUT8) PPStripBuildOutputCurve(8);
	if (gOutputLUT16) PPStripBuildOutputCurve(16);
}

