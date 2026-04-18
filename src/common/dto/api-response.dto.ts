import { ApiProperty } from '@nestjs/swagger';

export class ApiResponseDto<T> {
  @ApiProperty({ description: 'Indicates if the request was successful' })
  success: boolean;

  @ApiProperty({ description: 'Response message' })
  message?: string;

  @ApiProperty({ description: 'Actual response data' })
  data?: T;

  @ApiProperty({ description: 'Timestamp of the response' })
  timestamp: string = new Date().toISOString();

  constructor(success: boolean, message?: string, data?: T) {
    this.success = success;
    this.message = message;
    this.data = data;
  }
}
